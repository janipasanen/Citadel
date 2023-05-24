import Foundation
import Logging
import NIO
import NIOSSH

public struct TTYSTDError: Error {
    public let message: ByteBuffer
}

final class CollectingExecCommandHelper {
    let maxResponseSize: Int?
    var isIgnoringInput = false
    let mergeStreams: Bool
    let stdoutPromise: EventLoopPromise<ByteBuffer>?
    let stderrPromise: EventLoopPromise<ByteBuffer>?
    var stdout: ByteBuffer
    var stderr: ByteBuffer
    
    init(
        maxResponseSize: Int?,
        stdoutPromise: EventLoopPromise<ByteBuffer>?,
        stderrPromise: EventLoopPromise<ByteBuffer>?,
        mergeStreams: Bool,
        allocator: ByteBufferAllocator
    ) {
        self.maxResponseSize = maxResponseSize
        self.stdoutPromise = stdoutPromise
        self.stderrPromise = stderrPromise
        self.mergeStreams = mergeStreams
        self.stdout = allocator.buffer(capacity: 4096)
        self.stderr = allocator.buffer(capacity: 4096)
    }
    
    public func onOutput(_ channel: Channel, _ output: ExecCommandHandler.Output) {
        switch output {
        case .stderr(let byteBuffer) where mergeStreams:
            fallthrough
        case .stdout(let byteBuffer):
            if
                let maxResponseSize = maxResponseSize,
                stdout.readableBytes + byteBuffer.readableBytes > maxResponseSize
            {
                isIgnoringInput = true
                stdoutPromise?.fail(CitadelError.commandOutputTooLarge)
                stderrPromise?.fail(CitadelError.commandOutputTooLarge)
                return
            }
            
            stdout.writeImmutableBuffer(byteBuffer)
        case .stderr(let byteBuffer):
            if
                let maxResponseSize = maxResponseSize,
                stderr.readableBytes + byteBuffer.readableBytes > maxResponseSize
            {
                isIgnoringInput = true
                stdoutPromise?.fail(CitadelError.commandOutputTooLarge)
                stderrPromise?.fail(CitadelError.commandOutputTooLarge)
                return
            }
            
            stderr.writeImmutableBuffer(byteBuffer)
        case .eof(.some(let error)):
            stdoutPromise?.fail(error)
            stderrPromise?.fail(error)
        case .eof(.none):
            stdoutPromise?.succeed(stdout)
            stderrPromise?.succeed(stderr)
        case .channelSuccess:
            ()
        }
    }
}

public struct ExecCommandStream {
    public let stdout: AsyncThrowingStream<ByteBuffer, Error>
    public let stderr: AsyncThrowingStream<ByteBuffer, Error>
    
    struct Continuation {
        let stdout: AsyncThrowingStream<ByteBuffer, Error>.Continuation
        let stderr: AsyncThrowingStream<ByteBuffer, Error>.Continuation
        
        func onOutput(_ output: ExecCommandHandler.Output) {
            switch output {
            case .stdout(let buffer):
                stdout.yield(buffer)
            case .stderr(let buffer):
                stderr.yield(buffer)
            case .eof(let error):
                stdout.finish(throwing: error)
                stderr.finish(throwing: error)
            case .channelSuccess:
                ()
            }
        }
    }
}

public enum ExecCommandOutput {
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
}


final class ExecCommandHandler: ChannelDuplexHandler {
    enum Output {
        case channelSuccess
        case stdout(ByteBuffer)
        case stderr(ByteBuffer)
        case eof(Error?)
    }
    
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let logger: Logger
    let onOutput: (Channel, Output) -> ()
    
    init(logger: Logger, onOutput: @escaping (Channel, Output) -> ()) {
        self.logger = logger
        self.onOutput = onOutput
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIOSSH.ChannelSuccessEvent:
            onOutput(context.channel, .channelSuccess)
        case is NIOSSH.ChannelFailureEvent:
            onOutput(context.channel, .eof(CitadelError.channelFailure))
        case is SSHChannelRequestEvent.ExitStatus:
            ()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        onOutput(context.channel, .eof(nil))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = data.data else {
            logger.error("Unable to process channelData for executed command. Data was not a ByteBuffer")
            return onOutput(context.channel, .eof(SSHExecError.invalidData))
        }
        
        switch data.type {
        case .channel:
            onOutput(context.channel, .stdout(buffer))
        case .stdErr:
            onOutput(context.channel, .stderr(buffer))
        default:
            // We don't know this std channel
            ()
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onOutput(context.channel, .eof(error))
    }
}

extension SSHClient {
    /// Executes a command on the remote server. This will return the output of the command (stdout). If the command fails, the error will be thrown. If the output is too large, the command will fail.
    /// - Parameters:
    /// - command: The command to execute.
    /// - maxResponseSize: The maximum size of the response. If the response is larger, the command will fail.
    /// - mergeStreams: If the answer should also include stderr.
    public func executeCommand(_ command: String, maxResponseSize: Int = .max, mergeStreams: Bool = false) async throws -> ByteBuffer {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        
        let channel: Channel
        
        do {
            channel = try await eventLoop.flatSubmit {
                let createChannel = self.eventLoop.makePromise(of: Channel.self)
                self.session.sshHandler.createChannel(createChannel) { channel, _ in
                    let collecting = CollectingExecCommandHelper(
                        maxResponseSize: maxResponseSize,
                        stdoutPromise: promise,
                        stderrPromise: nil,
                        mergeStreams: mergeStreams,
                        allocator: channel.allocator
                    )
                    
                    return channel.pipeline.addHandlers(
                        ExecCommandHandler(logger: self.logger, onOutput: collecting.onOutput)
                    )
                }
                
                self.eventLoop.scheduleTask(in: .seconds(15)) {
                    createChannel.fail(CitadelError.channelCreationFailed)
                }
                
                return createChannel.futureResult
            }.get()
        } catch {
            promise.fail(error)
            throw error
        }
        
        // We need to exec a thing.
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        
        return try await eventLoop.flatSubmit {
            channel.triggerUserOutboundEvent(execRequest).whenFailure { [channel] error in
                channel.close(promise: nil)
                promise.fail(error)
            }
            
            return promise.futureResult
        }.get()
    }

    /// Executes a command on the remote server. This will return the output stream of the command. If the command fails, the error will be thrown.
    /// - Parameters:
    /// - command: The command to execute.
    public func executeCommandStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        var streamContinuation: AsyncThrowingStream<ExecCommandOutput, Error>.Continuation!
        let stream = AsyncThrowingStream<ExecCommandOutput, Error> { continuation in
            streamContinuation = continuation
        }
        
        let handler = ExecCommandHandler(logger: logger) { channel, output in
            switch output {
            case .stdout(let stdout):
                streamContinuation.yield(.stdout(stdout))
            case .stderr(let stderr):
                streamContinuation.yield(.stderr(stderr))
            case .eof(let error):
                streamContinuation.finish(throwing: error)
            case .channelSuccess:
                ()
            }
        }
        
        let channel = try await eventLoop.flatSubmit {
            let createChannel = self.eventLoop.makePromise(of: Channel.self)
            self.session.sshHandler.createChannel(createChannel) { channel, _ in
                channel.pipeline.addHandlers(handler)
            }
            
            self.eventLoop.scheduleTask(in: .seconds(15)) {
                createChannel.fail(CitadelError.channelCreationFailed)
            }
            
            return createChannel.futureResult
        }.get()
        
        // We need to exec a thing.
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        
        try await channel.triggerUserOutboundEvent(execRequest)
        
        return stream
    }

    /// Requests a shell to be invoked and executes a command on the remote server.
    /// - Parameters:
    /// - command: The command to execute.
    public func executeInShellStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        var streamContinuation: AsyncThrowingStream<ExecCommandOutput, Error>.Continuation!
        let stream = AsyncThrowingStream<ExecCommandOutput, Error> { continuation in
            streamContinuation = continuation
        }
        var hasReceivedChannelSuccess = false
        let handler = ExecCommandHandler(logger: logger) { channel, output in
            switch output {
            case .channelSuccess:
                if !hasReceivedChannelSuccess {
                    let commandData = SSHChannelData(type: .channel,
                                                     data: .byteBuffer(ByteBuffer(string: command+";exit\n")))
                    channel.writeAndFlush(commandData, promise: nil)
                    hasReceivedChannelSuccess = true
                }
            case let .stderr(buffer):
                streamContinuation.yield(.stderr(buffer))
            case let .stdout(buffer):
                streamContinuation.yield(.stdout(buffer))
            case .eof(let error):
                streamContinuation.finish(throwing: error)
            }
        }
        
        let channel = try await eventLoop.flatSubmit {
            let createChannel = self.eventLoop.makePromise(of: Channel.self)
            self.session.sshHandler.createChannel(createChannel) { channel, _ in
                channel.pipeline.addHandlers(handler)
            }
            
            self.eventLoop.scheduleTask(in: .seconds(15)) {
                createChannel.fail(CitadelError.channelCreationFailed)
            }
            
            return createChannel.futureResult
        }.get()
        
        let shellRequest = SSHChannelRequestEvent.ShellRequest(
            wantReply: true
        )
        
        try await channel.triggerUserOutboundEvent(shellRequest)
        
        return stream
    }

    /// Requests a shell to be invoked and executes a command on the remote server. This will return the pair of streams stdout and stderr of the command. If the command fails, the error will be thrown.
    /// - Parameters:
    /// - command: The command to execute.
    public func executeInShellPair(_ command: String) async throws -> ExecCommandStream {
        try await self.executePair(executeInShellStream(command))
    }
    
    /// Executes a command on the remote server. This will return the pair of streams stdout and stderr of the command. If the command fails, the error will be thrown.
    /// - Parameters:
    /// - command: The command to execute.
    public func executeCommandPair(_ command: String) async throws -> ExecCommandStream {
        try await self.executePair(executeCommandStream(command))
    }

    internal func executePair(_ stream: AsyncThrowingStream<ExecCommandOutput, Error>) async throws -> ExecCommandStream {
        var stdoutContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation!
        var stderrContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation!
        let stdout = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            stdoutContinuation = continuation
        }
        
        let stderr = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            stderrContinuation = continuation
        }
        
        let handler = ExecCommandStream.Continuation(
            stdout: stdoutContinuation,
            stderr: stderrContinuation
        )
        
        Task {
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer):
                        handler.stdout.yield(buffer)
                    case .stderr(let buffer):
                        handler.stderr.yield(buffer)
                    }
                }
                
                handler.stdout.finish()
                handler.stderr.finish()
            } catch {
                handler.stdout.finish(throwing: error)
                handler.stderr.finish(throwing: error)
            }
        }
        
        return ExecCommandStream(stdout: stdout, stderr: stderr)
    }
}
