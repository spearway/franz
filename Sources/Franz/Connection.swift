//
//  Connection.swift
//  Franz
//
//  Created by Kellan Cummings on 1/13/16.
//  Copyright © 2016 Kellan Cummings. All rights reserved.
//

import Foundation

enum ConnectionError: Error {
    case unableToOpenConnection
    case invalidIpAddress
    case cannotProcessMessageData
    case invalidCorrelationId
    case noResponse
    case zeroLengthResponse
    case partialResponse(size: Int32)
    case inputStreamUnavailable
    case inputStreamError
    case unableToFindInputStream
    case outputStreamUnavailable
    case outputStreamError(error: String)
    case outputStreamHasEnded
    case outputStreamClosed
    case unableToWriteBytes
    case bytesNoLongerAvailable
}


extension Stream.Event {
	var description: String {
		switch self {
		case []:
			return "None"
		case .openCompleted:
			return "Open Completed"
		case .hasBytesAvailable:
			return "Has Bytes Available"
		case .hasSpaceAvailable:
			return "Has Space Available"
		case .errorOccurred:
			return "Error Occurred"
		case .endEncountered:
			return "End Encountered"
		default:
			return ""
		}
	}
}

extension Stream.Status {
	var description: String {
		switch self {
		case .notOpen:
			return "Not Open"
		case .opening:
			return "Opening"
		case .open:
			return "Open"
		case .reading:
			return "Reading"
		case .writing:
			return "Writing"
		case .atEnd:
			return  "End"
		case .closed:
			return "Closed"
		case .error:
			return "Error"
		}
	}
}

class Connection: NSObject, StreamDelegate {
	
	enum AuthenticationError: Error {
		case unsupportedMechanism(supportedMechanisms: [String])
		case authenticationFailed
	}
    
    private var host: String
	private var port: Int32

    private var requestCallbacks = [Int32: ((Data?) -> Void)]()
	
    private var clientId: String
	
    private var readStream: Unmanaged<CFReadStream>?
    private var writeStream: Unmanaged<CFWriteStream>?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    
    private let responseLengthSize: Int32 = 4
    private let responseCorrelationIdSize: Int32 = 4

    private var inputStreamQueue: DispatchQueue
    private var outputStreamQueue: DispatchQueue
    private var writeRequestBlocks = [()->()]()
	
	private var runLoop: RunLoop?
	
	struct Config {
		let host: String
		let port: Int32
		let clientId: String
		let authentication: Cluster.Authentication
	}
    
	init(config: Config) throws {
        self.host = config.host
        self.clientId = config.clientId
        self.port = config.port

        inputStreamQueue = DispatchQueue(label: "\(self.host).\(self.port).input.stream.franz")
		outputStreamQueue = DispatchQueue(label: "\(self.host).\(self.port).output.stream.franz")

        super.init()

        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            host as CFString,
            UInt32(port),
            &readStream,
            &writeStream
        )

        inputStream = readStream?.takeUnretainedValue()
        outputStream = writeStream?.takeUnretainedValue()
		
		DispatchQueue(label: "FranzConnection").async {
			self.inputStream?.delegate = self
			self.inputStream?.schedule(
				in: RunLoop.current,
				forMode: RunLoopMode.defaultRunLoopMode
			)
			
			self.outputStream?.delegate = self
			self.outputStream?.schedule(
				in: RunLoop.current,
				forMode: RunLoopMode.defaultRunLoopMode
			)
			
			self.inputStream?.open()
			self.outputStream?.open()
			
			self.runLoop = RunLoop.current
			RunLoop.current.run()
		}
		
		// authenticate
		if let mechanism = config.authentication.mechanism {
			let handshakeRequest = SaslHandshakeRequest(mechanism: mechanism.kafkaLabel)
			guard let response = writeBlocking(handshakeRequest) else {
				throw AuthenticationError.authenticationFailed
			}
			
			guard response.errorCode == 0 else {
				throw AuthenticationError.unsupportedMechanism(supportedMechanisms: response.enabledMechanisms)
			}
			
			if !mechanism.authenticate(connection: self) {
				throw AuthenticationError.authenticationFailed
			}
		}

    }
    
    private func read(_ timeout: Double = 3000) {
        inputStreamQueue.async {
			guard let inputStream = self.inputStream else {
				print("Unable to find Input Stream")
				return
			}
			do {
				let (size, correlationId) = try self.getMessageMetadata()
				var bytes = [UInt8]()
				let startTime = Date().timeIntervalSince1970
				while bytes.count < Int(size) {
					
					if inputStream.hasBytesAvailable {
						var buffer = [UInt8](repeating: 0, count: Int(size))
						let bytesInBuffer = inputStream.read(&buffer, maxLength: Int(size))
						bytes += buffer.prefix(upTo: Int(bytesInBuffer))
					}
					
					let currentTime = Date().timeIntervalSince1970
					let timeDelta = (currentTime - startTime) * 1000
					
					if  timeDelta >= timeout {
						print("Timeout @ Delta \(timeDelta).")
						break
					}
				}
				
				if let callback = self.requestCallbacks[correlationId] {
					self.requestCallbacks.removeValue(forKey: correlationId)
					callback(Data(bytes: bytes))
				} else {
					print(
						"Unable to find request callback for " +
						"Correlation Id: \(correlationId)"
					)
				}
			} catch ConnectionError.zeroLengthResponse {
				print("Zero length response")
			} catch ConnectionError.partialResponse(let size) {
				print("Response Size: \(size) is invalid.")
			} catch ConnectionError.bytesNoLongerAvailable {
				return
			} catch {
				print("Error")
			}
        }
    }
	
	private static var correlationId: Int32 = 0
	func makeCorrelationId() -> Int32 {
		var id: Int32!
		DispatchQueue(label: "FranzMakeCorrelationId").sync {
			id = Connection.correlationId
			Connection.correlationId += 1
		}
		return id
	}
	
	func write<T: KafkaRequest>(_ request: T, callback: @escaping (T.Response) -> Void) {
		self.write(request, callback: callback, errorCallback: nil)
	}
	
	private func write<T: KafkaRequest>(_ request: T, callback: @escaping (T.Response) -> Void, errorCallback: (() -> Void)?) {

		let corId = makeCorrelationId()
		requestCallbacks[corId] = { data in
			if var mutableData = data {
				callback(T.Response.init(data: &mutableData))
			} else {
				errorCallback?()
			}
		}
		let dispatchBlock = DispatchWorkItem(qos: .unspecified, flags: []) {
			guard let stream = self.outputStream else {
				return
			}
			guard stream.hasSpaceAvailable else {
				print("No Space Available for Writing")
				return
			}
			let data = request.data(correlationId: corId, clientId: self.clientId)
			data.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
				stream.write(bytes, maxLength: data.count)
			}
		}
		
		if let outputStream = outputStream {
			if outputStream.hasSpaceAvailable {
				outputStreamQueue.async(execute: dispatchBlock)
			} else {
				writeRequestBlocks.append(dispatchBlock.perform)
			}
		} else {
			writeRequestBlocks.append(dispatchBlock.perform)
		}
    }
	
	func writeBlocking<T: KafkaRequest>(_ request: T) -> T.Response? {
		let semaphore = DispatchSemaphore(value: 0)
		var response: T.Response?
		write(request, callback: { r in
			response = r
			semaphore.signal()
		}, errorCallback: {
			semaphore.signal()
		})
		semaphore.wait()
		return response
	}
	
    private func getMessageMetadata() throws -> (Int32, Int32) {
		guard let activeInputStream = inputStream else {
			throw ConnectionError.unableToFindInputStream
		}
			
		let length = responseLengthSize + responseCorrelationIdSize
		var buffer = Array<UInt8>(repeating: 0, count: Int(length))
		if activeInputStream.hasBytesAvailable {
			activeInputStream.read(&buffer, maxLength: Int(length))
		} else {
			throw ConnectionError.bytesNoLongerAvailable
		}
		let sizeBytes = buffer.prefix(upTo: Int(responseLengthSize))
		buffer.removeFirst(Int(responseLengthSize))
		
		var sizeData = Data(bytes: sizeBytes)
		let responseLengthSizeInclusive = Int32(data: &sizeData)
		
		if responseLengthSizeInclusive > 4 {
			let correlationIdSizeBytes = buffer.prefix(upTo: Int(responseCorrelationIdSize))
			buffer.removeFirst(Int(responseCorrelationIdSize))
			
			var correlationIdSizeData = Data(bytes: correlationIdSizeBytes)
			return (
				responseLengthSizeInclusive - responseLengthSize,
				Int32(data: &correlationIdSizeData)
			)
		} else if responseLengthSizeInclusive == 0 {
			throw ConnectionError.zeroLengthResponse
		} else {
			throw ConnectionError.partialResponse(size: responseLengthSizeInclusive)
		}
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
		if eventCode == .endEncountered || eventCode == .errorOccurred {
			close()
			return
		}
        if let inputStream = aStream as? InputStream {
            let status = inputStream.streamStatus
            switch status {
            case .open:
                switch eventCode {
                case Stream.Event.hasBytesAvailable:
                    read()
                case Stream.Event.openCompleted:
                    return
                default:
                    print("STREAM EVENT: \(eventCode.description)")
                }
            case .reading:
                return
			case .error, .atEnd, .closed:
                print("INPUT STREAM ERROR: \(aStream.streamError?.localizedDescription ?? String())")
				close()
				return
            default:
                print("INPUT STREAM STATUS: \(aStream.streamStatus.description)")
                return
            }
        } else if let outputStream = aStream as? OutputStream {
            let status = outputStream.streamStatus
            switch status {
            case .open:
                switch eventCode {
                case Stream.Event.hasSpaceAvailable:
                    if writeRequestBlocks.count > 0 {
                        let block = writeRequestBlocks.removeFirst()
                        outputStreamQueue.async(execute: block)
                    }
                case Stream.Event.openCompleted:
                    return
                default:
                    print("OUTPUT STREAM EVENT: \(eventCode.description)")
                }
            case .writing:
                return
            case .error, .atEnd, .closed:
                print("OUTPUT STREAM ERROR: \(aStream.streamError?.localizedDescription ?? String())")
				close()
                return
            default:
                print("OUTPUT STREAM STATUS:: \(aStream.streamStatus.description)")
                return
            }
        }
    }
	
	/// Closes the connection and removes any streams from the RunLoop.
	func close() {
		print("Closing connection")
		inputStream?.close()
		outputStream?.close()
		if let runLoop = runLoop {
			inputStream?.remove(from: runLoop, forMode: .defaultRunLoopMode)
			outputStream?.remove(from: runLoop, forMode: .defaultRunLoopMode)
		}
		requestCallbacks.forEach { $1(nil) }
	}
}
