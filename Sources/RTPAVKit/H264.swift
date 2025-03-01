//
//  File.swift
//  
//
//  Created by David Nadoba on 20.04.20.
//

import Foundation
import CoreMedia
import VideoToolbox
import SwiftRTP
import BinaryKit
import Network

// MARK: - CMSampleBuffer to NALUnit

public enum SampleBufferToNALUnitConvertError: Error {
    case lengthHeaderIsSmallerThanOne
}

public extension CMSampleBuffer {
    @inlinable
    func convertToH264NALUnitsAndAddPPSAndSPSIfNeeded<D>(dataType: D.Type = D.self) -> [H264.NALUnit<D>] where D: DataProtocol, D.Index == Int, D: ReferenceInitalizeableData {
        var nalus = self.convertToH264NALUnits(dataType: D.self)
        if nalus.contains(where: { $0.header.type == H264.NALUnitType.instantaneousDecodingRefreshCodedSlice }),
            let formatDescription = self.formatDescription {
            let parameterSet = formatDescription.h264ParameterSets(dataType: D.self)
            nalus.insert(contentsOf: parameterSet, at: 0)
        }
        return nalus
    }
    @inlinable
    func convertToH264NALUnits<D>(dataType: D.Type = D.self) -> [H264.NALUnit<D>] where D: DataProtocol, D.Index == Int, D: ReferenceInitalizeableData {
        var nalus = [H264.NALUnit<D>]()
        CMSampleBufferCallBlockForEachSample(self) { (buffer, count) -> OSStatus in
            if let dataBuffer = buffer.dataBuffer, let formatDescription = formatDescription  {
                do {
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer)
                    guard OSStatusError.isSuccessfull(status), let unwrappedPointer = pointer else {
                        throw OSStatusError(status, description: "CMBlockBufferGetDataPointer failed")
                    }
                    
                    let newNalus = try unwrappedPointer.withMemoryRebound(to: UInt8.self, capacity: length) { (pointer) -> [H264.NALUnit<D>] in
                        let storage = UnsafeBufferPointer(start: pointer, count: length)
                        var reader = BinaryReader(bytes: storage)
                        var newNalus = [H264.NALUnit<D>]()
                        let nalUnitHeaderLength = formatDescription.nalUnitHeaderLength
                        while !reader.isEmpty {
                            let length = try reader.readInteger(byteCount: Int(nalUnitHeaderLength), type: UInt64.self)
                            guard length >= 1 else { throw SampleBufferToNALUnitConvertError.lengthHeaderIsSmallerThanOne }
                            let header = try H264.NALUnitHeader(from: &reader)
                            let payload = D(
                                referenceOrCopy: try reader.readBytes(Int(length) - 1),
                                deallocator: { [dataBuffer] in _ = dataBuffer }
                            )
                            newNalus.append(H264.NALUnit<D>(header: header, payload: payload))
                        }
                        return newNalus
                    }
                    
                    nalus.append(contentsOf: newNalus)
                } catch {
                    print(error, #file, #line)
                }
            }
            return KERN_SUCCESS
        }
        return nalus
    }
}

public extension CMFormatDescription {
    @inlinable
    var nalUnitHeaderLength: Int32 {
        var nalUnitHeaderLength: Int32 = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(self, parameterSetIndex: -1, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        return nalUnitHeaderLength
    }
    @inlinable
    func h264ParameterSets<D>(dataType: D.Type = D.self) -> [H264.NALUnit<D>] where D: DataProtocol, D.Index == Int, D: ReferenceInitalizeableData {
        var nalus = [H264.NALUnit<D>]()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(self, parameterSetIndex: -1, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for index in 0..<count {
            do {
                var pointerOut: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(self, parameterSetIndex: index, parameterSetPointerOut: &pointerOut, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointerOut = pointerOut {
                    let data = UnsafeBufferPointer(start: pointerOut, count: size)
                    var reader = BinaryReader(bytes: data)
                    let nalu = H264.NALUnit(
                        header: try .init(from: &reader),
                        payload: D(referenceOrCopy: try reader.readRemainingBytes(),
                                   deallocator: { [self] in _ = self }))
                    nalus.append(nalu)
                } else {
                    print("could not get H264ParameterSet")
                }
            } catch {
                print(error, #file, #line)
            }
        }
        return nalus
    }
}

// MARK: - Sender

extension CVPixelBuffer {
    /// Returns the width of the PixelBuffer in pixels.
    var width: Int { CVPixelBufferGetWidth(self) }
    /// Returns the height of the PixelBuffer in pixels.
    var height: Int { CVPixelBufferGetHeight(self) }
}

public final class RTPH264Sender {
    public enum State {
        case setup
        case prepairing
        case connected
        case failed
        case canceled
    }
    public typealias IntermediateData = [UInt8]
    public typealias PayloadData = DispatchData
    public typealias DidChangeStateCallback = (State) -> ()
    private let queue: DispatchQueue
    private let collectionQueue: DispatchQueue = DispatchQueue(label: "de.nadoba.\(RTPH264Sender.self).data-transfer-report-collection")
    private var encoder: VideoEncoder?
    private var connection: NWConnection
    private var rtpSerialzer: RTPSerialzer = .init(maxSizeOfPacket: 9216, synchronisationSource: RTPSynchronizationSource(rawValue: .random(in: UInt32.min...UInt32.max)))
    private lazy var h264Serialzer: H264.NALNonInterleavedPacketSerializer<IntermediateData, PayloadData> = .init(maxSizeOfNalu: rtpSerialzer.maxSizeOfPayload)
    public var onCollectConnectionMetric: ((NWConnection.DataTransferReport) -> ())?
    public var didChangeState: DidChangeStateCallback?
    
    
    private var _state: State = .setup {
        didSet {
            didChangeState?(_state)
        }
    }
    public var state: State { queue.sync { _state } }
    
    private let timeoutInterval: DispatchTimeInterval = .milliseconds(3000)
    
    public init(connection: NWConnection, queue: DispatchQueue) {
        self.queue = queue
        self.connection = connection
        start(on: connection)
    }
    public func start() {
        start(on: connection)
    }
    private func start(on connection: NWConnection) {
        guard _state == .setup else { return }
        _state = .prepairing
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self._state = .connected
                self.resetTimeout()
                self.scheduleRecieveKeepAlive(on: connection)
            case .cancelled:
                self.cancel()
            case let .failed(error):
                self.failed(error: error)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    public func cancel() {
        guard _state == .connected || _state == .prepairing || _state == .setup else { return }
        _state = .canceled
        connection.cancel()
    }
    private func failed(error: NWError) {
        print("connection failed \(error)")
        guard _state == .prepairing || _state == .setup || _state == .connected else { return }
        _state = .failed
    }
    
    private func scheduleRecieveKeepAlive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            guard self._state == .connected || self._state == .prepairing else { return }
            defer {
                self.scheduleRecieveKeepAlive(on: connection)
            }
            guard isComplete else {
                print("did recieve incomplete message error: \(error as Any)")
                return
            }
            if let error = error {
                print(error)
                return
            }
            guard let data = data else {
                print("recive message is complete and no error but also no data")
                return
            }
            let expectedPayload = "keep alive".data(using: .utf8)
            guard data == expectedPayload else {
                print("recieved message contains wrong payload. Expected: \(String(decoding: data, as: UTF8.self)) Recieved: \(String(decoding: data, as: UTF8.self))")
                return
            }
            self.resetTimeout()
        }
    }
    
    // MARK: - Timeout
    private var lastTimeoutWorkItem: DispatchWorkItem?
    private func resetTimeout() {
        guard _state == .connected else { return }
        lastTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.timeout()
        }
        lastTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
    private func timeout() {
        guard _state == .connected || _state == .prepairing else {
            _state = .failed
            connection.cancel()
            return
        }
    }
    
    @discardableResult
    public func setupEncoderIfNeeded(width: Int, height: Int) throws -> VideoEncoder {
        if let encoder = self.encoder, encoder.width == width, encoder.height == height {
            return encoder
        }
        
        #if os(macOS)
        let encoderSpecification = EncoderSpecification(
            requireHardwareAcceleratedVideoEncoder: true,
            enableHardwareAcceleratedVideoEncoder: true
        )
        #else
        let encoderSpecification = EncoderSpecification()
        #endif
        
        let encoder = try VideoEncoder(
            width: width,
            height: height,
            codec: .h264,
            encoderSpecification: encoderSpecification)
        
        encoder.allowFrameReordering = false
        encoder.realTime = true
        
        encoder.callback = { [weak self] buffer, flags in
            self?.sendBuffer(buffer)
        }
        
        self.encoder = encoder
        return encoder
    }
    
    private var frameCount: Int = 0
    
    public func encodeAndSendFrame(_ frame: CVPixelBuffer, presentationTimeStamp: CMTime, frameDuration: CMTime) {
        guard self._state == .connected else { return }
        frameCount += 1
        do {
            let encoder = try setupEncoderIfNeeded(width: frame.width, height: frame.height)
            try encoder.encodeFrame(imageBuffer: frame, presentationTimeStamp: presentationTimeStamp, duration: frameDuration, frameProperties: [
                kVTEncodeFrameOptionKey_ForceKeyFrame: frameCount.isMultiple(of: 30),
            ])
        } catch {
            print(error, #file, #line)
        }
    }
    private var firstTimestampValue: Int64?
    private func getTimestampValueOffset(for timestampValue: Int64) -> Int64 {
        guard let firstTimestampValue = firstTimestampValue else {
            self.firstTimestampValue = timestampValue
            return timestampValue
        }
        return firstTimestampValue
    }
    private func sendBuffer(_ sampleBuffer: CMSampleBuffer) {
        let nalus = sampleBuffer.convertToH264NALUnitsAndAddPPSAndSPSIfNeeded(dataType: PayloadData.self)
        let timestampValue = sampleBuffer.presentationTimeStamp.convertScale(90_000, method: .default).value
        let timestamp = UInt32(timestampValue - getTimestampValueOffset(for: timestampValue))
        sendNalus(nalus, timestamp: timestamp)
    }
    private var dataTransferReportCollectionInterval: TimeInterval = 1
    private var currentDataTransferReportStartTime: TimeInterval?
    private var currentDataTransferReport: NWConnection.PendingDataTransferReport?
    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
    private func shouldStartNewDataTransferReportReport() -> Bool {
        guard let currentDataTransferReportStartTime = currentDataTransferReportStartTime else { return true }
        let elapsedSeconds = now() - currentDataTransferReportStartTime
        return elapsedSeconds > dataTransferReportCollectionInterval
    }
    private func startAndCollectDataTransferReportIfNeeded() {
        guard let onCollectConnectionMetric = onCollectConnectionMetric else { return }
        guard shouldStartNewDataTransferReportReport() else { return }
        let newDataTransferReport = connection.startDataTransferReport()
        /// `.collection()` does crash if the interface is nil with error message:
        /// ```
        /// nw_data_transfer_report_copy_path_interface called with null (path_index < report->path_count)
        /// ```
        /// To reproduce this problem, connect to a Bonjour name that does not exists on the current network.
        if connection.currentPath?.localEndpoint?.interface != nil {
            currentDataTransferReport?.collect(queue: collectionQueue, completion: { report in
                onCollectConnectionMetric(report)
            })
        }
        currentDataTransferReport = newDataTransferReport
        currentDataTransferReportStartTime = now()
    }
    private func sendNalus(_ nalus: [H264.NALUnit<PayloadData>], timestamp: UInt32) {
        guard connection.maximumDatagramSize > 0 else { return }
        rtpSerialzer.maxSizeOfPacket = min(9216, connection.maximumDatagramSize)
        h264Serialzer.maxSizeOfNaluPacket = rtpSerialzer.maxSizeOfPayload
        
        startAndCollectDataTransferReportIfNeeded()
        
        do {
            let packets = try h264Serialzer.serialize(nalus, timestamp: timestamp, lastNALUsForGivenTimestamp: true)
            let ipMetadata = NWProtocolIP.Metadata()
            //ipMetadata.serviceClass = .interactiveVideo
            let context = NWConnection.ContentContext(
                identifier: "RTP",
                metadata: [ipMetadata]
            )
            connection.batch {
                for packet in packets {
                    do {
                        
                        let data: PayloadData = try rtpSerialzer.serialze(packet)
                        connection.send(content: data, contentContext: context, completion: .contentProcessed({ error in
                            if let error = error, self._state == .connected {
                                print(error)
                            }
                        }))
                    } catch {
                        print(error, #file, #line)
                    }
                }
            }
        } catch {
            print(error, #file, #line)
        }
    }
}

// MARK: - NALUnit to CMSampleBuffer

public extension DataProtocol {
    func toCMBlockBuffer() throws -> CMBlockBuffer {
        let mutableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: self.count)
        self.copyBytes(to: mutableBuffer)
        
        
        var source = CMBlockBufferCustomBlockSource()
        source.refCon = UnsafeMutableRawPointer(mutableBuffer.baseAddress)
        source.FreeBlock = { refCon, _, _ in
            refCon?.deallocate()
        }
        
        var blockBuffer: CMBlockBuffer?
        
        let result = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,        // structureAllocator
            memoryBlock: UnsafeMutableRawPointer(mutableBuffer.baseAddress),          // memoryBlock
            blockLength: mutableBuffer.count,                // blockLength
            blockAllocator: kCFAllocatorNull,           // blockAllocator
            customBlockSource: &source,                    // customBlockSource
            offsetToData: 0,                          // offsetToData
            dataLength: mutableBuffer.count,                // dataLength
            flags: 0,                          // flags
            blockBufferOut: &blockBuffer)               // newBBufOut
        
        try OSStatusError.check(result, errorDescription: "CMBlockBufferCreateWithMemoryBlock")
        
        assert(CMBlockBufferGetDataLength(blockBuffer!) == mutableBuffer.count)
        return blockBuffer!
        
    }
}

fileprivate let h264ClockRate: Int32 = 90_000

enum SampleBufferError: Error {
    case canNotCreateBufferFromZeroNalus
    case canNotCreateBufferFromNalusOfDifferentHeaders
}

extension H264.NALUnit where D == Data {
    public func sampleBuffer(formatDescription: CMFormatDescription, time: CMTime, duration: CMTime = .invalid) throws -> CMSampleBuffer {
        // Prepend the size of the data to the data as a 32-bit network endian uint. (keyword: "elementary stream")
        let offset = 0
        let size = UInt32((self.payload.count - offset) + 1)
        
        let prefix = size.toNetworkByteOrder.data + Data([self.header.byte])
        var data = prefix.withUnsafeBytes{ (header) in
            DispatchData(bytes: header)
        }
        assert(data.count == 5)
        self.payload.withUnsafeBytes { (payload) in
            let payload = UnsafeRawBufferPointer(start: payload.baseAddress!.advanced(by: offset), count: payload.count - offset)
            data.append(payload)
        }
        assert(data.count == size + 4)
        
        let blockBuffer = try data.toCMBlockBuffer()
        
        // So what about STAP???? From CMSampleBufferCreate "Behavior is undefined if samples in a CMSampleBuffer (or even in multiple buffers in the same stream) have the same presentationTimeStamp"
        
        // Computer the duration and time
        
        
        
        // Inputs to CMSampleBufferCreate
        let timingInfo: [CMSampleTimingInfo] = [CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)]
        let sampleSizes: [Int] = [CMBlockBufferGetDataLength(blockBuffer)]
        
        // Outputs from CMSampleBufferCreate
        var sampleBuffer: CMSampleBuffer?
        
        let result = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,            // allocator: CFAllocator?,
            dataBuffer: blockBuffer,                    // dataBuffer: CMBlockBuffer?,
            dataReady: true,                           // dataReady: Boolean,
            makeDataReadyCallback: nil,                            // makeDataReadyCallback: CMSampleBufferMakeDataReadyCallback?,
            refcon: nil,                            // makeDataReadyRefcon: UnsafeMutablePointer<Void>,
            formatDescription: formatDescription,              // formatDescription: CMFormatDescription?,
            sampleCount: 1,                              // numSamples: CMItemCount,
            sampleTimingEntryCount: timingInfo.count,               // numSampleTimingEntries: CMItemCount,
            sampleTimingArray: timingInfo,                     // sampleTimingArray: UnsafePointer<CMSampleTimingInfo>,
            sampleSizeEntryCount: sampleSizes.count,              // numSampleSizeEntries: CMItemCount,
            sampleSizeArray: sampleSizes,                    // sampleSizeArray: UnsafePointer<Int>,
            sampleBufferOut: &sampleBuffer                   // sBufOut: UnsafeMutablePointer<Unmanaged<CMSampleBuffer>?>
        )
        
        
        guard OSStatusError.isSuccessfull(result),
            let unwrapedSampleBuffer = sampleBuffer else {
            throw OSStatusError(result, description: "CMSampleBufferCreate() failed")
        }
        
        //    if let attachmentsOfSampleBuffers = CMSampleBufferGetSampleAttachmentsArray(unwrapedSampleBuffer, createIfNecessary: true) as? [NSMutableDictionary] {
        //        for attachments in attachmentsOfSampleBuffers {
        //            attachments[kCMSampleAttachmentKey_DisplayImmediately] = NSNumber(value: true)
        //        }
        //    }
        
        return unwrapedSampleBuffer
    }
}

public final class VideoDecoder {
    public typealias Callback = (_ imageBuffer: CVPixelBuffer?, _ presentationTimeStamp: CMTime, _ presentationDuration: CMTime) -> ()
    fileprivate var session: VTDecompressionSession!
    public var callback: Callback?
    public init(formatDescription: CMVideoFormatDescription) throws {
        var session: VTDecompressionSession?
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (selfPointer, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                let mySelf = Unmanaged<VideoDecoder>.fromOpaque(UnsafeRawPointer(selfPointer!)).takeUnretainedValue()
                do {
                    try OSStatusError.check(status, errorDescription: "VTDecompressionOutputCallbackRecorddecompressionOutputCallback")
                } catch {
                    print(error)
                }
                mySelf.decompressionOutputCallback(imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
        },
            decompressionOutputRefCon: ptr)
        let status = withUnsafePointer(to: callback) { (callbackPointer) in
            VTDecompressionSessionCreate(
                allocator: nil,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: callbackPointer, decompressionSessionOut: &session)
        }
        
        guard OSStatusError.isSuccessfull(status), let unwrapedSession = session else {
            throw OSStatusError(status, description: "failed to create \(VTDecompressionSession.self) from \(formatDescription)")
        }
        self.session = unwrapedSession
    }
    private func decompressionOutputCallback(imageBuffer: CVPixelBuffer?, presentationTimeStamp: CMTime, presentationDuration: CMTime) {
        callback?(imageBuffer, presentationTimeStamp, presentationDuration)
    }
    @discardableResult
    public func decodeFrame(sampleBuffer: CMSampleBuffer, flags: VTDecodeFrameFlags = VTDecodeFrameFlags()) throws -> VTDecodeInfoFlags {
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                          sampleBuffer: sampleBuffer,
                                          flags: flags,
                                          frameRefcon: nil,
                                          infoFlagsOut: &infoFlags)
        
        try OSStatusError.check(status, errorDescription: "failed to decode frame \(sampleBuffer) info flags: \(infoFlags)")
        return infoFlags
    }
    public func canAcceptFormatDescription(_ formatDescription: CMFormatDescription) -> Bool {
        VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDescription)
    }
}

public final class RTPH264ReceiverListener {
    private let queue = DispatchQueue(label: "de.nadoba.\(RTPH264Reciever.self).udp")
    private let listen: NWListener
    private let timebase: CMTimebase
    private var currentReciever: RTPH264Reciever?
    public var newConnectionHandler: ((RTPH264Reciever) -> ())?
    private var _state: RTPH264Reciever.State = .setup
    
    public var state: RTPH264Reciever.State {
        get {
            return _state
        }
    }

    public init(port: NWEndpoint.Port, timebase: CMTimebase) {
        self.timebase = timebase
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: port)
        listen = try! NWListener(using: parameters)
        
        listen.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            
            let reciever = RTPH264Reciever(connection: connection, timebase: timebase)
            self.currentReciever = reciever
            self.newConnectionHandler?(reciever)
            self._state = (currentReciever?.state)!
            reciever.start()
        }
    }
    
    public func start() {
        listen.start(queue: queue)
    }
    
    deinit {
        listen.cancel()
    }
}

public final class RTPH264Reciever {
    public enum State {
        case setup
        case prepairing
        case connected
        case failed
        case canceled
    }
    public typealias SampleBufferCallback = (CMSampleBuffer) -> ()
    public typealias FormatDescriptinoCallback = (CMVideoFormatDescription) -> ()
    public typealias DidChangeStateCallback = (State) -> ()
    public let connection: NWConnection
    public var didRecieveSampleBuffer: SampleBufferCallback?
    public var didRecieveFormatDescription: FormatDescriptinoCallback?
    public var didChangeState: DidChangeStateCallback?
    private var timeManager: VideoPresentationTimeManager
    private var _state: State = .setup {
        didSet {
            didChangeState?(_state)
        }
    }
    public var state: State { queue.sync { _state } }
    private let queue: DispatchQueue
    private let timeoutInterval: DispatchTimeInterval = .milliseconds(1000)
    private let keepAliveMessageInterval: DispatchTimeInterval = .milliseconds(50)
    
    public init(connection: NWConnection, timebase: CMTimebase, target: DispatchQueue? = nil) {
        timeManager = .init(timebase: timebase)
        self.connection = connection
        self.queue = DispatchQueue(label: "RTPAVKit.\(RTPH264Reciever.self)", target: target)
    }

    deinit {
        cancel()
    }
    
    public func updateTimebase(_ timebase: CMTimebase) {
        queue.async { [weak self] in
            self?.timeManager = VideoPresentationTimeManager(timebase: timebase)
        }
    }
    
    public func start() {
        self.start(connection: connection)
    }
    private func start(connection: NWConnection) {
        guard _state == .setup else { return }
        _state = .prepairing
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.resetTimeout()
                self.sendKeepAliveMessage(on: connection, completion: .idempotent)
                self.scheduleKeepAliveMessage(on: connection)
                self.scheduleReciveMessage(on: connection)
            case .cancelled:
                self.cancel()
            case let .failed(error):
                self.failed(error: error)
            default: break
            }
        }
        connection.betterPathUpdateHandler = { betterPathAvailable in
            print("Better Path Available: \(betterPathAvailable)")
        }
        connection.start(queue: queue)
    }
    
    public func cancel() {
        guard _state == .connected || _state == .prepairing || _state == .setup else { return }
        _state = .canceled
        connection.cancel()
    }
    private func failed(error: NWError) {
        print("connection failed \(error)")
        guard _state == .prepairing || _state == .setup || _state == .connected else { return }
        _state = .failed
    }
    
    // MARK: - Keep Alive
    private func scheduleKeepAliveMessage(on connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + keepAliveMessageInterval) { [weak self] in
            guard let self = self else { return }
            self.sendKeepAliveMessage(on: connection, completion: .contentProcessed({ [weak self] (error) in
                if let error = error {
                    print(error)
                    return
                }
                self?.scheduleKeepAliveMessage(on: connection)
            }))
        }
    }
    private let keepAliveMessageContext: NWConnection.ContentContext = {
        let ipMetadata = NWProtocolIP.Metadata()
        ipMetadata.serviceClass = .signaling
        let context = NWConnection.ContentContext(identifier: "keep alive", metadata: [ipMetadata])
        return context
    }()
    private func sendKeepAliveMessage(on connection: NWConnection, completion: NWConnection.SendCompletion) {
        guard _state == .prepairing || _state == .connected else { return }
        connection.send(content: "keep alive".data(using: .utf8)!, contentContext: keepAliveMessageContext, completion: completion)
    }
    
    // MARK: - Timeout
    private var lastTimeoutWorkItem: DispatchWorkItem?
    private func resetTimeout() {
        lastTimeoutWorkItem?.cancel()
        guard _state == .prepairing || _state == .connected else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.timeout()
        }
        lastTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
    private func timeout() {
        guard _state != .canceled && _state != .failed else { return }
        _state = .failed
        connection.cancel()
    }
    
    private func scheduleReciveMessage(on: NWConnection) {
        on.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            guard self._state == .connected || self._state == .prepairing else { return }
            defer {
                self.scheduleReciveMessage(on: on)
            }
            guard isComplete else {
                print("did recieve incomplete message error: \(error as Any)")
                return
            }
            if let error = error {
                print(error)
                return
            }
            guard let data = data else {
                print("recive message is complete and no error but also no data")
                return
            }
            self.didReciveData(data)
        }
    }
    private func didReciveData(_ data: Data) {
        resetTimeout()
        if _state == .prepairing {
            _state = .connected
        }
        do {
            try parse(data)
        } catch {
            resetH264Parser()
            print(error)
        }
    }
    private var h264Parser = H264.NALNonInterleavedPacketParser<Data>()
    var prevSequenceNumber: SerialNumber<UInt16>?
    private func parse(_ data: Data) throws {
        var reader = BinaryReader(bytes: data)
        let header = try RTPHeader(from: &reader)
        defer { prevSequenceNumber = header.sequenceNumber }
        if let prevSequenceNumber = prevSequenceNumber,
            prevSequenceNumber >= header.sequenceNumber {
            print("packets in wrong order prevSequenceNumber: \(prevSequenceNumber) current: \(header.sequenceNumber)")
            resetH264Parser()
        }
        if let prevSequenceNumber = prevSequenceNumber,
            header.sequenceNumber != (prevSequenceNumber + 1) {
            print("packet lost prevSequenceNumber: \(prevSequenceNumber) current: \(header.sequenceNumber)")
            resetH264Parser()
        }
        let nalUnits = try h264Parser.readPackage(from: &reader)
        if !nalUnits.isEmpty {
            didReciveNALUnits(nalUnits, header: header)
        }
    }
    
    private func resetH264Parser() {
        h264Parser = .init()
    }
    
    private var sequenceParameterSet: H264.NALUnit<Data>? {
        didSet {
            if oldValue != sequenceParameterSet {
                formatDescription = nil
            }
        }
    }
    private var pictureParameterSet: H264.NALUnit<Data>? {
        didSet {
            if oldValue != pictureParameterSet {
                formatDescription = nil
            }
        }
    }
    private var formatDescription: CMVideoFormatDescription?
    
    private func didReciveNALUnits(_ nalus: [H264.NALUnit<Data>], header: RTPHeader) {
        for nalu in nalus {
            self.didReciveNALUnit(nalu, header: header)
        }
        if formatDescription == nil,
            let sequenceParameterSet = self.sequenceParameterSet,
            let pictureParameterSet = self.pictureParameterSet {
            do {
                let formatDescription = try CMVideoFormatDescriptionCreateForH264From(
                    sequenceParameterSet: sequenceParameterSet,
                    pictureParameterSet: pictureParameterSet
                )
                self.formatDescription = formatDescription
                formatDescription.map { formatDescription in
                    didRecieveFormatDescription?(formatDescription)
                }
            } catch {
                print(error)
            }
        }
        
        
        for vclNalu in nalus.filter({ $0.header.type.isVideoCodingLayer }) {
            didReciveVCLNALU(vclNalu, header: header)
        }
    }
    private func didReciveNALUnit(_ nalu: H264.NALUnit<Data>, header: RTPHeader) {
        if nalu.header.type == .sequenceParameterSet {
            sequenceParameterSet = nalu
            formatDescription = nil
        }
        if nalu.header.type == .pictureParameterSet {
            pictureParameterSet = nalu
            formatDescription = nil
        }
    }
    private func didReciveVCLNALU(_ nalu: H264.NALUnit<Data>, header: RTPHeader) {
        guard let formatDescription = formatDescription else {
            print("did recieve VCL NALU of type \(nalu.header.type) before formatDescription is ready")
            return
        }
        let presentationTime = timeManager.getPresentationTime(for: Int64(header.timestamp))
        do {
            let buffer = try nalu.sampleBuffer(formatDescription: formatDescription, time: presentationTime, duration: .invalid)
            didRecieveSampleBuffer?(buffer)
        } catch {
            print(error)
        }
    }
}

func CMVideoFormatDescriptionCreateForH264From(sequenceParameterSet: H264.NALUnit<Data>, pictureParameterSet: H264.NALUnit<Data>) throws -> CMVideoFormatDescription? {
    try sequenceParameterSet.bytes.withUnsafeBytes { (sequenceParameterPointer: UnsafeRawBufferPointer) in
        try pictureParameterSet.bytes.withUnsafeBytes { (pictureParameterPointers: UnsafeRawBufferPointer) in
            let parameterBuffers = [
                sequenceParameterPointer,
                pictureParameterPointers,
            ]
            let parameters = parameterBuffers.map({ $0.baseAddress!.assumingMemoryBound(to: UInt8.self) })
            let paramterSizes = parameterBuffers.map(\.count)
            var formatDescription: CMFormatDescription?

            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil,
                parameterSetCount: parameters.count,
                parameterSetPointers: parameters,
                parameterSetSizes: paramterSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescription)
            guard OSStatusError.isSuccessfull(status), let unwrapedFormatDescription = formatDescription else {
                throw OSStatusError(status)
            }
            return unwrapedFormatDescription
        }
    }
}

extension BinaryFloatingPoint {
    @inlinable
    public func interpolatedValue(to end: Self, at position: Double) -> Self {
        let start = self
        return (end - start) * Self(position) + start
    }
}

public struct VideoPresentationTimeManager {
    public static let rtpClockRate: Int32 = 90_000
    var timescale: Int32
    var initalBufferTime: CMTime
    var bufferDelay: CMTime?
    var timebase: CMTimebase
    public init(initalBufferTime: CMTime, timescale: Int32 = VideoPresentationTimeManager.rtpClockRate, timebase: CMTimebase) {
        self.initalBufferTime = initalBufferTime
        self.timescale = timescale
        self.timebase = timebase
    }
    public init(
        innitalBufferTimeInSeconds: TimeInterval = 0,//6ms
        timescale: Int32 = VideoPresentationTimeManager.rtpClockRate,
        timebase: CMTimebase
    ) {
        self.init(initalBufferTime: CMTime(seconds: innitalBufferTimeInSeconds, preferredTimescale: timescale), timescale: timescale, timebase: timebase)
    }
    private func makeTime(from timestamp: Int64) -> CMTime {
        CMTime(value: timestamp, timescale: timescale)
    }
    private func getDelay() -> CMTime {
        bufferDelay ?? initalBufferTime
    }
    var remoteStartTime: CMTime?
    private mutating func getRemoteOffset(for time: CMTime) -> CMTime {
        guard let firstTimestamp = remoteStartTime else {
            self.resetRemoteStart(to: time)
            return .zero
        }
        return time - firstTimestamp
    }
    var localStartTime: CMTime?
    var prevOffset: CMTime?
    private mutating func resetRemoteStart(to time: CMTime) {
        self.remoteStartTime = time
        self.localStartTime = nil
    }
    public mutating func getPresentationTime(for timestamp: Int64) -> CMTime {
        let time = makeTime(from: timestamp)
        var timeOffset = getRemoteOffset(for: time)
        defer { prevOffset = timeOffset }
        // reset offset if needed
        if let prevOffset = prevOffset {
            let difference = abs(timeOffset.seconds - prevOffset.seconds)
            if difference > 1 {
                resetRemoteStart(to: time)
                timeOffset = .zero
            }
        }
        let localStartTime: CMTime = {
            guard let localStartTime = self.localStartTime else {
                let now = timebase.time.convertScale(timescale, method: .default)
                self.localStartTime = now
                return now
            }
            return localStartTime
        }()
        let localTimestamp = localStartTime + timeOffset
        //let absDrif = (localTimestamp + getDelay() - timebase.time).seconds

        //print("drift", absDrif * 1000, "ms")
        let currentDelay = getDelay().seconds
        //print("currentDelay:", currentDelay * 1000, "ms")
        let destinationDelay = (timebase.time - localTimestamp).seconds + 0.016
        let newDelay = currentDelay.interpolatedValue(to: destinationDelay, at: 0.05)


        bufferDelay = CMTime(seconds: newDelay, preferredTimescale: timescale)
        return localTimestamp + getDelay()
        //return timebase.time
    }
//    public mutating func getPresentationTime(for timestamp: Int64) -> CMTime {
//        CMClockGetHostTimeClock().time
//    }
}
