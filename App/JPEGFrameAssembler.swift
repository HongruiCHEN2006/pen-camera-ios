import Foundation

struct JPEGFrameAssembler {
    private var buffer = [UInt8]()
    let maximumFrameLength: Int
    private(set) var droppedFrameCount = 0

    init(maximumFrameLength: Int = 5 * 1_024 * 1_024) {
        self.maximumFrameLength = maximumFrameLength
    }

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var completedFrames = [Data]()

        while true {
            guard let start = marker(0xFF, 0xD8, from: 0) else {
                buffer = buffer.last == 0xFF ? [0xFF] : []
                break
            }

            if start > 0 {
                buffer.removeFirst(start)
            }

            let end = marker(0xFF, 0xD9, from: 2)
            let newerStart = marker(0xFF, 0xD8, from: 2)

            if let newerStart, end == nil || newerStart < end! {
                buffer.removeFirst(newerStart)
                droppedFrameCount += 1
                continue
            }

            if let end {
                let frameEnd = end + 2
                completedFrames.append(Data(buffer[0..<frameEnd]))
                buffer.removeFirst(frameEnd)
                continue
            }

            if buffer.count > maximumFrameLength {
                buffer = buffer.last == 0xFF ? [0xFF] : []
                droppedFrameCount += 1
            }
            break
        }

        return completedFrames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func marker(_ first: UInt8, _ second: UInt8, from start: Int) -> Int? {
        guard buffer.count >= 2, start < buffer.count - 1 else { return nil }
        for index in start..<(buffer.count - 1) where buffer[index] == first && buffer[index + 1] == second {
            return index
        }
        return nil
    }
}
