//
//  Util.swift
//  DL4S
//
//  Created by Palle Klewitz on 07.03.19.
//  Copyright (c) 2019 - Palle Klewitz
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation


extension Sequence {
    func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
        return try lazy.filter(predicate).count
    }
}

func shapeForBroadcastedOperands(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
    let dim = Swift.max(lhs.count, rhs.count)
    let pLhs = Array(repeating: 1, count: dim - lhs.count) + lhs
    let pRhs = Array(repeating: 1, count: dim - rhs.count) + rhs
    return zip(pLhs, pRhs).map(Swift.max)
}

func iterate(_ shape: [Int]) -> [[Int]] {
    var result: [[Int]] = []
    
    let count = shape.reduce(1, *)
    result.reserveCapacity(count)
    
    let strides = MemoryOps.strides(from: shape)
    
    for i in 0 ..< count {
        result.append(zip(shape, strides).map {(i / $1) % $0})
    }
    
    return result
}

prefix func ! <Parameters>(predicate: @escaping (Parameters) -> Bool) -> (Parameters) -> Bool {
    return { params in
        !predicate(params)
    }
}

extension Slice: Equatable where Element: Hashable {
    public static func == (lhs: Slice<Base>, rhs: Slice<Base>) -> Bool {
        return lhs.count == rhs.count && !zip(lhs, rhs).map(==).contains(false)
    }
}

extension Slice: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        for element in self {
            hasher.combine(element)
        }
    }
}

extension Collection {
    func minIndex(by comparator: (Element, Element) throws -> Bool) rethrows -> Index? {
        var minIndex: Index? = nil
        var minValue: Element? = nil
        for index in indices {
            if let mv = minValue, try !comparator(mv, self[index]) {
                minIndex = index
                minValue = self[index]
            }
        }
        return minIndex
    }
}


extension DispatchSemaphore {
    func execute<Result>(_ block: () throws -> Result) rethrows -> Result {
        self.wait()
        let result = try block()
        self.signal()
        return result
    }
}


public class Queue<Element> {
    private let sema = DispatchSemaphore(value: 0)
    private let maxLenSema: DispatchSemaphore?
    private let lock = DispatchSemaphore(value: 1)
    
    public private(set) var isStopped: Bool = false
    public let maxLength: Int?
    private var collection: [Element] = []
    
    public init(maxLength: Int? = nil) {
        self.maxLength = maxLength
        if let maxLength = maxLength {
            self.maxLenSema = DispatchSemaphore(value: maxLength)
        } else {
            self.maxLenSema = nil
        }
    }
    
    public func enqueue(_ element: Element) {
        maxLenSema?.wait()
        if isStopped {
            maxLenSema?.signal()
            return
        }
        lock.execute {
            collection.append(element)
        }
        sema.signal()
    }
    
    public func dequeue() -> Element? {
        sema.wait()
        
        if isStopped {
            sema.signal()
            return nil
        }
        
        let result = lock.execute {
            self.collection.removeFirst()
        }
        maxLenSema?.signal()
        return result
    }
    
    public func stop() {
        lock.execute {
            self.isStopped = true
        }
        maxLenSema?.signal()
        sema.signal()
    }
}


fileprivate let intervalFormatter: DateComponentsFormatter = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.locale = Locale(identifier: "en")
    
    let formatter = DateComponentsFormatter()
    
    formatter.calendar = calendar
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.includesApproximationPhrase = true
    formatter.includesTimeRemainingPhrase = true
    formatter.unitsStyle = .positional
    
    return formatter
}()


public struct ProgressBar<UserInfo> {
    public let totalUnitCount: Int
    public private(set) var currentUnitCount: Int
    public let formatUserInfo: (UserInfo) -> String
    public let label: String
    private var startTime = Date()
    
    public init(totalUnitCount: Int, formatUserInfo: @escaping (UserInfo) -> String, label: String) {
        self.totalUnitCount = totalUnitCount
        self.formatUserInfo = formatUserInfo
        self.label = label
        self.currentUnitCount = 0
    }
    
    public mutating func next(userInfo: UserInfo) {
        currentUnitCount += 1
        
        let interval = Date().timeIntervalSince(startTime)
        let perUnitDuration = interval / Double(currentUnitCount)
        let remainingDuration = perUnitDuration * Double(totalUnitCount - currentUnitCount)
        let remainingString = intervalFormatter.string(from: remainingDuration)!
        
        
        let filled = String(repeating: "#", count: currentUnitCount * 30 / totalUnitCount)
        let empty = String(repeating: " ", count: 30 - (currentUnitCount * 30 / totalUnitCount))
        print("\r\u{1b}[K\(label) [\(filled)\(empty)] (\(currentUnitCount)/\(totalUnitCount) - \(remainingString)) \(formatUserInfo(userInfo))", terminator: "")
        fflush(stdout)
    }
    
    public mutating func complete() {
        self.currentUnitCount = self.totalUnitCount
        print("\r\u{1b}[K\(label): Done.")
    }
}


public struct Progress<Element>: Sequence {
    private struct ProgressIterator<Element>: IteratorProtocol {
        var baseIterator: AnyIterator<Element>
        let totalUnitCount: Int
        var currentCount: Int
        let label: String?
        let unit: String?
        
        mutating func next() -> Element? {
            if let next = baseIterator.next() {
                currentCount += 1
                print(completed: currentCount, total: totalUnitCount)
                return next
            } else {
                printCompleted()
                return nil
            }
        }
        
        func print(completed: Int, total: Int) {
            let filled = String(repeating: "#", count: currentCount * 30 / totalUnitCount)
            let empty = String(repeating: " ", count: 30 - (currentCount * 30 / totalUnitCount))
            
            let label = self.label.map {"\($0) "} ?? ""
            let unitString = unit.map {"\($0) "} ?? ""
            let userInfo = "(\(unitString)\(currentCount)/\(totalUnitCount))"
            
            Swift.print("\r\033[K\(label)[\(filled)\(empty)] \(userInfo)", terminator: "")
            fflush(stdout)
        }
        
        func printCompleted() {
            Swift.print("\r\033[K", terminator: "")
            if let label = self.label {
                Swift.print("\(label): ", terminator: "")
            }
            Swift.print("Done.")
        }
    }
    
    private let base: AnySequence<Element>
    public var label: String?
    public var unit: String?
    
    public init<S: Sequence>(_ sequence: S, label: String? = nil, unit: String? = nil) where S.Element == Element {
        self.base = AnySequence(sequence)
        self.label = label
        self.unit = unit
    }
    
    public __consuming func makeIterator() -> AnyIterator<Element> {
        let baseIterator = base.makeIterator()
        let progressIterator = ProgressIterator(
            baseIterator: baseIterator,
            totalUnitCount: base.underestimatedCount,
            currentCount: 0,
            label: label,
            unit: unit
        )
        return AnyIterator(progressIterator)
    }
}


