import Foundation
import func Evergreen.getLogger
import HAP
import SMC

fileprivate let logger = getLogger("demo")

#if os(macOS)
    import Darwin
#elseif os(Linux)
    import Dispatch
    import Glibc
#endif

getLogger("hap").logLevel = .debug
getLogger("hap.encryption").logLevel = .warning

let storage = FileStorage(filename: "configuration.json")
if CommandLine.arguments.contains("--recreate") {
    logger.info("Dropping all pairings, keys")
    try storage.write(Data())
}

#if DEBUG
SMC.shared.printSystemInformation()
#endif

let cpu = Accessory.Thermometer(
    info: Service.Info(name: "CPU", serialNumber: SMC.Sensor.CPU.proximity)
)
let gpu = Accessory.Thermometer(
    info: Service.Info(name: "GPU", serialNumber: SMC.Sensor.GPU.proximity)
)
var fans: [Accessory.Fan] = []
for fan in SMC.shared.fans() {
    let item = Accessory.Fan(
        info: Service.Info(name: "Fan-\(fan.identifier)", serialNumber: "\(fan.identifier)")
    )
    fans.append(item)
}

let accessories: [Accessory] = [ cpu, gpu ] + fans

let device = Device(
    bridgeInfo: Service.Info(name: "Bridge", serialNumber: "00001"),
    setupCode: "123-44-321",
    storage: storage,
    accessories: accessories
)

class MyDeviceDelegate: DeviceDelegate {
    func didRequestIdentificationOf(_ accessory: Accessory) {
        logger.info("Requested identification "
            + "of accessory \(String(describing: accessory.info.name.value ?? ""))")
    }

    func characteristic<T>(_ characteristic: GenericCharacteristic<T>,
                           ofService service: Service,
                           ofAccessory accessory: Accessory,
                           didChangeValue newValue: T?) {
        logger.info("Characteristic \(characteristic) "
            + "in service \(service.type) "
            + "of accessory \(accessory.info.name.value ?? "") "
            + "did change: \(String(describing: newValue))")
    }

    func characteristicListenerDidSubscribe(_ accessory: Accessory,
                                            service: Service,
                                            characteristic: AnyCharacteristic) {
        logger.info("Characteristic \(characteristic) "
            + "in service \(service.type) "
            + "of accessory \(accessory.info.name.value ?? "") "
            + "got a subscriber")
    }

    func characteristicListenerDidUnsubscribe(_ accessory: Accessory,
                                              service: Service,
                                              characteristic: AnyCharacteristic) {
        logger.info("Characteristic \(characteristic) "
            + "in service \(service.type) "
            + "of accessory \(accessory.info.name.value ?? "") "
            + "lost a subscriber")
    }
    
    func didChangePairingState(from: PairingState, to: PairingState) {
        if to == .notPaired {
            printPairingInstructions()
        }
    }
    
    func printPairingInstructions() {
        if device.isPaired {
            print()
            print("The device is paired, either unpair using your iPhone or remove the configuration file `configuration.json`.")
            print()
        } else {
            print()
            print("Scan the following QR code using your iPhone to pair this device:")
            print()
            print(device.setupQRCode.asText)
            print()
        }
    }
}

var delegate = MyDeviceDelegate()
device.delegate = delegate
let server = try Server(device: device, listenPort: 8000)

// Stop server on interrupt.
var keepRunning = true
func stop() {
    DispatchQueue.main.async {
        logger.info("Shutting down...")
        keepRunning = false
    }
}
signal(SIGINT) { _ in stop() }
signal(SIGTERM) { _ in stop() }

print("Initializing the server...")

// Switch the lights every 5 seconds.
let timer = DispatchSource.makeTimerSource()
timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
timer.setEventHandler(handler: {
    if let temperature = SMC.shared.cpuTemperature() {
        cpu.temperatureSensor.currentTemperature.value = Float(temperature.celsius)
    }
    if let temperature = SMC.shared.gpuTemperature() {
        gpu.temperatureSensor.currentTemperature.value = Float(temperature.celsius)
    }
    for (index, fan) in SMC.shared.fans().enumerated() {
        if let currentRPM = fan.currentRPM {
            fans[index].fan.powerState.value = currentRPM > 0
            fans[index].fan.rotationSpeed?.value = Float(currentRPM)
        }
    }
})
timer.resume()

delegate.printPairingInstructions()

withExtendedLifetime([delegate]) {
    if CommandLine.arguments.contains("--test") {
        print("Running runloop for 10 seconds...")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
    } else {
        while keepRunning {
            RunLoop.current.run(mode: .default, before: Date.distantFuture)
        }
    }
}

try server.stop()
logger.info("Stopped")
