//
//  LibreTransmitterManager.swift
//  Created by Bjørn Inge Berg on 25/02/2019.
//  Copyright © 2019 Bjørn Inge Berg. All rights reserved.
//

import Foundation

import UIKit
import UserNotifications
import Combine

import CoreBluetooth
import HealthKit
import os.log

public final class LibreTransmitterManager: CGMManager, LibreTransmitterDelegate {

    public let logger = Logger.init(subsystem: "no.bjorninge.libre", category: "LibreTransmitterManager")


    public let isOnboarded = true   // No distinction between created and onboarded

    public var hasValidSensorSession: Bool {
        lastConnected != nil 
    }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(hasValidSensorSession: hasValidSensorSession)
    }

    public var glucoseDisplay: GlucoseDisplayable?

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) {

    }

    public func getSoundBaseURL() -> URL? {
        nil
    }

    public func getSounds() -> [Alert.Sound] {
        []
    }

    public func libreManagerDidRestoreState(found peripherals: [CBPeripheral], connected to: CBPeripheral?) {
        let devicename = to?.name  ?? "no device"
        let id = to?.identifier.uuidString ?? "null"
        let msg = "Bluetooth State restored (Loop restarted?). Found \(peripherals.count) peripherals, and connected to \(devicename) with identifier \(id)"
        NotificationHelper.sendRestoredStateNotification(msg: msg)
    }

    public var batteryLevel: Double? {
        let batt = self.proxy?.metadata?.battery
        logger.debug("dabear:: LibreTransmitterManager was asked to return battery: \(batt.debugDescription)")
        //convert from 8% -> 0.8
        if let battery = proxy?.metadata?.battery {
            return Double(battery) / 100
        }

        return nil
    }

    public func noLibreTransmitterSelected() {
        NotificationHelper.sendNoTransmitterSelectedNotification()
    }

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            return delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return delegate.queue
        }
        set {
            delegate.queue = newValue
        }
    }

    public let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()



    public var managedDataInterval: TimeInterval?

    public var device: HKDevice? {
         //proxy?.OnQueue_device
        proxy?.device
    }

    private func getPersistedSensorDataForDebug() -> String {
        guard let data = UserDefaults.standard.queuedSensorData else {
            return "nil"
        }

        let c = self.calibrationData?.description ?? "no calibrationdata"
        return data.array.map {
            "SensorData(uuid: \"0123\".data(using: .ascii)!, bytes: \($0.bytes))!"
        }
        .joined(separator: ",\n")
        + ",\n Calibrationdata: \(c)"
    }

    public var debugDescription: String {

        return [
            "## LibreTransmitterManager",
            "Testdata: foo",
            "lastConnected: \(String(describing: lastConnected))",
            "Connection state: \(connectionState)",
            "Sensor state: \(sensorStateDescription)",
            "transmitterbattery: \(batteryString)",
            "SensorData: \(getPersistedSensorDataForDebug())",
            "Metainfo::\n\(AppMetaData.allProperties)",
            ""
        ].joined(separator: "\n")
    }

    //public var miaomiaoService: MiaomiaoService

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        logger.debug("dabear:: fetchNewDataIfNeeded called but we don't continue")

        completion(.noData)
    }

    public private(set) var lastConnected: Date?

    public private(set) var alarmStatus = AlarmStatus()

    public private(set) var latestBackfill: LibreGlucose? {
        willSet(newValue) {
            guard let newValue = newValue else {
                return
            }

            var trend: GlucoseTrend?
            let oldValue = latestBackfill

            defer {
                logger.debug("dabear:: sending glucose notification")
                NotificationHelper.sendGlucoseNotitifcationIfNeeded(glucose: newValue,
                                                                    oldValue: oldValue,
                                                                    trend: trend,
                                                                    battery: batteryString)

                //once we have a new glucose value, we can update the isalarming property
                if let activeAlarms = UserDefaults.standard.glucoseSchedules?.getActiveAlarms(newValue.glucoseDouble) {
                    DispatchQueue.main.async {
                        self.alarmStatus.isAlarming = ([.high,.low].contains(activeAlarms))
                        self.alarmStatus.glucoseScheduleAlarmResult = activeAlarms
                    }
                } else {
                    DispatchQueue.main.async {
                    self.alarmStatus.isAlarming = false
                    self.alarmStatus.glucoseScheduleAlarmResult = .none
                    }
                }


            }

            logger.debug("dabear:: latestBackfill set, newvalue is \(newValue.description)")

            if let oldValue = oldValue {
                // the idea here is to use the diff between the old and the new glucose to calculate slope and direction, rather than using trend from the glucose value.
                // this is because the old and new glucose values represent earlier readouts, while the trend buffer contains somewhat more jumpy (noisy) values.
                let timediff = LibreGlucose.timeDifference(oldGlucose: oldValue, newGlucose: newValue)
                logger.debug("dabear:: timediff is \(timediff)")
                let oldIsRecentEnough = timediff <= TimeInterval.minutes(15)

                trend = oldIsRecentEnough ? newValue.GetGlucoseTrend(last: oldValue) : nil

                var batteries : [(name: String, percentage: Int)]?
                if let metaData = metaData, let battery = battery {
                    batteries = [(name: metaData.name, percentage: battery)]
                }

                self.glucoseDisplay = ConcreteGlucoseDisplayable(isStateValid: newValue.isStateValid, trendType: trend, isLocal: true, batteries: batteries)
            } else {
                //could consider setting this to ConcreteSensorDisplayable with trendtype GlucoseTrend.flat, but that would be kinda lying
                self.glucoseDisplay = nil
            }
        }

    }

    public var managerIdentifier : String {
        Self.className
    }

    public required convenience init?(rawState: CGMManager.RawStateValue) {

        self.init()
        logger.debug("dabear:: LibreTransmitterManager  has run init from rawstate")
    }

    public var rawState: CGMManager.RawStateValue {
        [:]
    }


    public let localizedTitle = LocalizedString("Libre Bluetooth", comment: "Title for the CGMManager option")

    public let appURL: URL? = nil //URL(string: "spikeapp://")

    public let providesBLEHeartbeat = true
    public var shouldSyncToRemoteService: Bool {
        UserDefaults.standard.mmSyncToNs
    }

    public private(set) var lastValidSensorData: SensorData?

    public init() {
        lastConnected = nil
        //let isui = (self is CGMManagerUI)
        //self.miaomiaoService = MiaomiaoService(keychainManager: keychain)

        logger.debug("dabear: LibreTransmitterManager will be created now")
        //proxy = MiaoMiaoBluetoothManager()
        proxy?.delegate = self
    }

    public var calibrationData: SensorData.CalibrationInfo? {
        KeychainManagerWrapper.standard.getLibreNativeCalibrationData()
    }

    public func disconnect() {
        logger.debug("dabear:: LibreTransmitterManager disconnect called")

        proxy?.disconnectManually()
        proxy?.delegate = nil
    }

    deinit {
        logger.debug("dabear:: LibreTransmitterManager deinit called")
        //cleanup any references to events to this class
        disconnect()
    }

    private lazy var proxy: LibreTransmitterProxyManager? = LibreTransmitterProxyManager()

    private func readingToGlucose(_ data: SensorData, calibration: SensorData.CalibrationInfo) -> [LibreGlucose] {
        let last16 = data.trendMeasurements()

        var entries = LibreGlucose.fromTrendMeasurements(last16, nativeCalibrationData: calibration, returnAll: UserDefaults.standard.mmBackfillFromTrend)

        let text = entries.map { $0.description }.joined(separator: ",")
        logger.debug("dabear:: trend entries count: \(entries.count): \n \(text)" )
        if UserDefaults.standard.mmBackfillFromHistory {
            let history = data.historyMeasurements()
            entries += LibreGlucose.fromHistoryMeasurements(history, nativeCalibrationData: calibration)
        }

        return entries
    }

    public func handleGoodReading(data: SensorData?, _ callback: @escaping (LibreError?, [LibreGlucose]?) -> Void) {
        //only care about the once per minute readings here, historical data will not be considered

        guard let data = data else {
            callback(.noSensorData, nil)
            return
        }

        let calibrationdata = KeychainManagerWrapper.standard.getLibreNativeCalibrationData()

        if let calibrationdata = calibrationdata {
            logger.debug("dabear:: calibrationdata loaded")

            if calibrationdata.isValidForFooterWithReverseCRCs == data.footerCrc.byteSwapped {
                logger.debug("dabear:: calibrationdata correct for this sensor, returning last values")

                callback(nil, readingToGlucose(data, calibration: calibrationdata))
                return
            } else {
                logger.debug("dabear:: calibrationdata incorrect for this sensor, calibrationdata.isValidForFooterWithReverseCRCs: \(calibrationdata.isValidForFooterWithReverseCRCs),  data.footerCrc.byteSwapped: \(data.footerCrc.byteSwapped)")
            }
        } else {
            logger.debug("dabear:: calibrationdata was nil")
        }

        calibrateSensor(sensordata: data) { [weak self] calibrationparams  in
            do {
                try KeychainManagerWrapper.standard.setLibreNativeCalibrationData(calibrationparams)
            } catch {
                NotificationHelper.sendCalibrationNotification(.invalidCalibrationData)
                callback(.invalidCalibrationData, nil)
                return
            }
            //here we assume success, data is not changed,
            //and we trust that the remote endpoint returns correct data for the sensor

            NotificationHelper.sendCalibrationNotification(.success)
            callback(nil, self?.readingToGlucose(data, calibration: calibrationparams))
        }
    }

    //will be called on utility queue
    public func libreTransmitterStateChanged(_ state: BluetoothmanagerState) {
        switch state {
        case .Connected:
            lastConnected = Date()
        case .powerOff:
            NotificationHelper.sendBluetoothPowerOffNotification()
        default:
            break
        }
        return
    }

    //will be called on utility queue
    public func libreTransmitterReceivedMessage(_ messageIdentifier: UInt16, txFlags: UInt8, payloadData: Data) {
        guard let packet = MiaoMiaoResponseState(rawValue: txFlags) else {
            // Incomplete package?
            // this would only happen if delegate is called manually with an unknown txFlags value
            // this was the case for readouts that were not yet complete
            // but that was commented out in MiaoMiaoManager.swift, see comment there:
            // "dabear-edit: don't notify on incomplete readouts"
            logger.debug("dabear:: incomplete package or unknown response state")
            return
        }

        switch packet {
        case .newSensor:
            logger.debug("dabear:: new libresensor detected")
            NotificationHelper.sendSensorChangeNotificationIfNeeded()
        case .noSensor:
            logger.debug("dabear:: no libresensor detected")
            NotificationHelper.sendSensorNotDetectedNotificationIfNeeded(noSensor: true)
        case .frequencyChangedResponse:
            logger.debug("dabear:: transmitter readout interval has changed!")

        default:
            //we don't care about the rest!
            break
        }

        return
    }

    func tryPersistSensorData(with sensorData: SensorData) {
        guard UserDefaults.standard.shouldPersistSensorData else {
            return
        }

        //yeah, we really really need to persist any changes right away
        var data = UserDefaults.standard.queuedSensorData ?? LimitedQueue<SensorData>()
        data.enqueue(sensorData)
        UserDefaults.standard.queuedSensorData = data
    }


    /*
     These properties are mostly useful for swiftui
     */
    public var transmitterInfoObservable = TransmitterInfo()
    public var sensorInfoObservable = SensorInfo()
    public var glucoseInfoObservable = GlucoseInfo()

    func setObservables(sensorData: SensorData?, metaData: LibreTransmitterMetadata?) {
        logger.debug("dabear:: setObservables called")
        DispatchQueue.main.async {
            var sendTransmitterInfoUpdate  = false
            var sendSensorInfoUpdate = false
            var sendGlucoseInfoUpdate = false

            if let metaData=metaData {
                self.logger.debug("dabear::will set transmitterInfoObservable")
                self.transmitterInfoObservable.battery = metaData.batteryString
                self.transmitterInfoObservable.hardware = metaData.hardware
                self.transmitterInfoObservable.firmware = metaData.firmware
                self.transmitterInfoObservable.sensorType = metaData.sensorType()?.description ?? "Unknown"
                self.transmitterInfoObservable.transmitterIdentifier = metaData.macAddress ??  UserDefaults.standard.preSelectedDevice ?? "Unknown"
                sendTransmitterInfoUpdate = true

            }

            self.transmitterInfoObservable.connectionState = self.proxy?.connectionStateString ?? "n/a"
            self.transmitterInfoObservable.transmitterType = self.proxy?.shortTransmitterName ?? "Unknown"

            if let sensorData = sensorData {
                self.logger.debug("dabear::will set sensorInfoObservable")
                self.sensorInfoObservable.sensorAge = sensorData.humanReadableSensorAge
                self.sensorInfoObservable.sensorAgeLeft = sensorData.humanReadableTimeLeft

                self.sensorInfoObservable.sensorState = sensorData.state.description 
                self.sensorInfoObservable.sensorSerial = sensorData.serialNumber

                self.glucoseInfoObservable.checksum = String(sensorData.footerCrc.byteSwapped)

                sendGlucoseInfoUpdate = true


            }


            if let sensorEndTime = sensorData?.sensorEndTime {
                self.sensorInfoObservable.sensorEndTime = self.dateFormatter.string(from: sensorEndTime )
                sendSensorInfoUpdate = true
            } else {
                self.sensorInfoObservable.sensorEndTime = "Unknown or ended"
                sendSensorInfoUpdate = true
            }





            let formatter = QuantityFormatter()
            let unit = UserDefaults.standard.mmGlucoseUnit ?? .milligramsPerDeciliter
            formatter.setPreferredNumberFormatter(for: unit)


            if let d = self.latestBackfill {
                self.logger.debug("dabear::will set glucoseInfoObservable")
                self.glucoseInfoObservable.glucose = formatter.string(from: d.quantity, for: unit) ?? "-"
                self.glucoseInfoObservable.date = self.longDateFormatter.string(from: d.timestamp)
                sendGlucoseInfoUpdate = true
            }

            if sendGlucoseInfoUpdate {
                self.glucoseInfoObservable.objectWillChange.send()
            }

            if sendTransmitterInfoUpdate {
                self.transmitterInfoObservable.objectWillChange.send()
            }

            if sendSensorInfoUpdate {
                self.sensorInfoObservable.objectWillChange.send()
            }



        }


    }

    var longDateFormatter : DateFormatter = ({
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .long
        df.doesRelativeDateFormatting = true
        return df
    })()

    var dateFormatter : DateFormatter = ({
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .full
        df.locale = Locale.current
        return df
    })()

    private var countTimesWithoutData: Int = 0
    //will be called on utility queue
    public func libreTransmitterDidUpdate(with sensorData: SensorData, and Device: LibreTransmitterMetadata) {

        self.logger.debug("dabear:: got sensordata: \(String(describing: sensorData)), bytescount: \( sensorData.bytes.count), bytes: \(sensorData.bytes)")
        var sensorData = sensorData

        NotificationHelper.sendLowBatteryNotificationIfNeeded(device: Device)
        self.setObservables(sensorData: nil, metaData: Device)

         if !sensorData.isLikelyLibre1FRAM {
            if let patchInfo = Device.patchInfo, let sensorType = SensorType(patchInfo: patchInfo) {
                let needsDecryption = [SensorType.libre2, .libreUS14day].contains(sensorType)
                if needsDecryption, let uid = Device.uid {
                    sensorData.decrypt(patchInfo: patchInfo, uid: uid)
                }
            } else {
                logger.debug("Sensor type was incorrect, and no decryption of sensor was possible")
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(LibreError.encryptedSensor))
                return
            }
        }

        let typeDesc = Device.sensorType().debugDescription

        logger.debug("Transmitter connected to libresensor of type \(typeDesc). Details:  \(Device.description)")

        tryPersistSensorData(with: sensorData)

        NotificationHelper.sendInvalidSensorNotificationIfNeeded(sensorData: sensorData)
        NotificationHelper.sendInvalidChecksumIfDeveloper(sensorData)



        guard sensorData.hasValidCRCs else {
            self.delegateQueue.async {
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(LibreError.checksumValidationError))
            }

            logger.debug("did not get sensordata with valid crcs")
            return
        }

        NotificationHelper.sendSensorExpireAlertIfNeeded(sensorData: sensorData)

        guard sensorData.state == .ready || sensorData.state == .starting else {
            logger.debug("dabear:: got sensordata with valid crcs, but sensor is either expired or failed")
            self.delegateQueue.async {
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(LibreError.expiredSensor))
            }
            return
        }

        logger.debug("dabear:: got sensordata with valid crcs, sensor was ready")
        self.lastValidSensorData = sensorData



        self.handleGoodReading(data: sensorData) { [weak self] error, glucose in
            guard let self = self else {
                print("dabear:: handleGoodReading could not lock on self, aborting")
                return
            }
            if let error = error {
                self.logger.error("dabear:: handleGoodReading returned with error: \(error.errorDescription)")
                self.delegateQueue.async {
                    self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(error))
                }
                return
            }

            guard let glucose = glucose else {
                self.logger.debug("dabear:: handleGoodReading returned with no data")
                self.delegateQueue.async {
                    self.cgmManagerDelegate?.cgmManager(self, hasNew: .noData)
                }
                return
            }

            //We prefer to use local cached glucose value for the date to filter
            var startDate = self.latestBackfill?.startDate

            //
            // but that might not be available when loop is restarted for example
            //
            if startDate == nil {
                self.delegateQueue.sync {
                    startDate = self.cgmManagerDelegate?.startDateToFilterNewData(for: self)
                }
            }

            // add one second to startdate to make this an exclusive (non overlapping) match
            startDate = startDate?.addingTimeInterval(1)

            let device = self.proxy?.device
            let newGlucose = glucose
                .filterDateRange(startDate, nil)
                .filter { $0.isStateValid }
                .map {
                NewGlucoseSample(date: $0.startDate,
                                 quantity: $0.quantity,
                                 isDisplayOnly: false,
                                 wasUserEntered: false,
                                 syncIdentifier: $0.syncId,
                                 device: device)
                }

            if newGlucose.isEmpty {
                self.countTimesWithoutData &+= 1
            } else {
                self.latestBackfill = glucose.max { $0.startDate < $1.startDate }
                self.logger.debug("dabear:: latestbackfill set to \(self.latestBackfill.debugDescription)")
                self.countTimesWithoutData = 0
            }
            //must be inside this handler as setobservables "depend" on latestbackfill
            self.setObservables(sensorData: sensorData, metaData: nil)

            self.logger.debug("dabear:: handleGoodReading returned with \(newGlucose.count) entries")
            self.delegateQueue.async {
                var result: CGMReadingResult
                // If several readings from a valid and running sensor come out empty,
                // we have (with a large degree of confidence) a sensor that has been
                // ripped off the body
                if self.countTimesWithoutData > 1 {
                    result = .error(LibreError.noValidSensorData)
                } else {
                    result = newGlucose.isEmpty ? .noData : .newData(newGlucose)
                }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
            }
        }

    }
}



extension LibreTransmitterManager {

     static var className: String {
        String(describing: Self.self)
    }
    //cannot be called from managerQueue
    public var identifier: String {
        //proxy?.OnQueue_identifer?.uuidString ?? "n/a"
        proxy?.identifier?.uuidString ?? "n/a"
    }

    public var metaData: LibreTransmitterMetadata? {
        //proxy?.OnQueue_metadata
         proxy?.metadata
    }

    //cannot be called from managerQueue
    public var connectionState: String {
        //proxy?.connectionStateString ?? "n/a"
        proxy?.connectionStateString ?? "n/a"
    }
    //cannot be called from managerQueue
    public var sensorSerialNumber: String {
        //proxy?.OnQueue_sensorData?.serialNumber ?? "n/a"
        proxy?.sensorData?.serialNumber ?? "n/a"
    }

    //cannot be called from managerQueue
    public var sensorAge: String {
        //proxy?.OnQueue_sensorData?.humanReadableSensorAge ?? "n/a"
        proxy?.sensorData?.humanReadableSensorAge ?? "n/a"
    }

    public var sensorEndTime : String {
        if let endtime = proxy?.sensorData?.sensorEndTime  {
            let mydf = DateFormatter()
            mydf.dateStyle = .long
            mydf.timeStyle = .full
            mydf.locale = Locale.current
            return mydf.string(from: endtime)
        }
        return "Unknown or Ended"
    }

    public var sensorTimeLeft: String {
        //proxy?.OnQueue_sensorData?.humanReadableSensorAge ?? "n/a"
        proxy?.sensorData?.humanReadableTimeLeft ?? "n/a"
    }

    //cannot be called from managerQueue
    public var sensorFooterChecksums: String {
        //(proxy?.OnQueue_sensorData?.footerCrc.byteSwapped).map(String.init)
        (proxy?.sensorData?.footerCrc.byteSwapped).map(String.init)

            ?? "n/a"
    }



    //cannot be called from managerQueue
    public var sensorStateDescription: String {
        //proxy?.OnQueue_sensorData?.state.description ?? "n/a"
        proxy?.sensorData?.state.description ?? "n/a"
    }
    //cannot be called from managerQueue
    public var firmwareVersion: String {
        proxy?.metadata?.firmware ?? "n/a"
    }

    //cannot be called from managerQueue
    public var hardwareVersion: String {
        proxy?.metadata?.hardware ?? "n/a"
    }

    //cannot be called from managerQueue
    public var batteryString: String {
        proxy?.metadata?.batteryString ?? "n/a"
    }

    public var battery: Int? {
        proxy?.metadata?.battery
    }

    public func getDeviceType() -> String {
        proxy?.shortTransmitterName ?? "Unknown"
    }
    public func getSmallImage() -> UIImage? {
        proxy?.activePluginType?.smallImage ?? UIImage(named: "libresensor", in: Bundle.current, compatibleWith: nil)
    }
}


