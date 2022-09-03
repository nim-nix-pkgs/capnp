## Sending/receiving capn'p messages over stream in a same format as C++ RPC implementation.
import capnp, reactor, collections

proc readSegments*(stream: Input[byte]): Future[string] {.async.} =
  let segmentCount = int(await stream.readItem(uint32, littleEndian))
  if segmentCount > 512:
    raise newException(CapnpFormatError, "too many segments")

  var s = capnp.pack(segmentCount.uint32, littleEndian)

  var dataLength = 0
  for i in 0..segmentCount:
    let words = int(await stream.readItem(uint32, littleEndian))
    s &= capnp.pack(words.uint32, littleEndian)
    # FIXME: can this lead to DoS due to abort during overflow?
    dataLength += words * 8

  if segmentCount mod 2 == 1:
    discard (await stream.readItem(uint32, littleEndian))
    s &= "\0\0\0\0"

  if dataLength > capnp.bufferLimit:
    raise newException(CapnpFormatError, "message too long")

  s &= await stream.read(dataLength)
  when defined(caprpcPrintMessages):
    echo "message ", s.encodeHex
  return s

proc wrapByteInput*[T](stream: Input[byte], t: typedesc[T]): Input[T] {.asynciterator.} =
  ## Create a stream for receiving capn'p messages from byte stream.
  while true:
    let packed = await readSegments(stream)
    let val = newUnpacker(packed).unpackPointer(0, T)
    asyncYield val

proc pipeMsg[T](stream: Input[T], provider: ByteOutput) {.async.} =
  asyncFor msg in stream:
    let serialized = capnp.packPointer(msg)
    let lengthInWords = len(serialized) div 8
    assert len(serialized) mod 8 == 0
    let data = capnp.pack(0.uint32, littleEndian) & capnp.pack(lengthInWords.uint32, littleEndian) & serialized
    # echo "send ", data.encodeHex
    await provider.write(data)

proc wrapByteOutput*[T](byteprovider: ByteOutput, t: typedesc[T]): Output[T] =
  ## Create a provider for sending messages over byte provider.
  let (stream, provider) = newInputOutputPair[T]()
  pipeMsg(stream, byteprovider).onErrorClose(stream)
  return provider

proc wrapBytePipe*[T](pipe: BytePipe, t: typedesc[T]): Pipe[T] =
  return Pipe[T](input: wrapByteInput(pipe.input, T), output: wrapByteOutput(pipe.output, T))
