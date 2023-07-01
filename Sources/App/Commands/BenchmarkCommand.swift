import Foundation
import Vapor
import SwiftPFor2D

fileprivate extension String {
    func pad(_ n: Int) -> String {
        return padding(toLength: n, withPad: " ", startingAt: 0)
    }
    static func dash(_ n: Int) -> String {
        return "".padding(toLength: n, withPad: "-", startingAt: 0)
    }
}

final class BenchmarkCommand: Command {
    struct Signature: CommandSignature {
        @Option(name: "time", short: "t", help: "Time per test in seconds")
        var time: Int?
    }
    
    var timePerTest: Int = 0
    
    var help: String { "Benchmark Open-Meteo core functions like data manipulation and compression" }
    
    
    @discardableResult
    func measure<T>(_ section: String, _ baseLineMeanMs: Double, fn: () throws -> T) rethrows -> T
    {
        print("| \(section.pad(80)) | ", terminator: "")
        // Do not measure first execution
        var result = try fn()
        
        let start = DispatchTime.now()
        let end = start.advanced(by: .seconds(timePerTest))
        var min = 100.0
        var max = 0.0
        var count = 0
        
        repeat {
            let s = DispatchTime.now()
            result = try fn()
            count += 1
            let elapsed = Double((DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds)) / 1_000_000_000
            if elapsed < min {
                min = elapsed
            }
            if elapsed > max {
                max = elapsed
            }
        } while DispatchTime.now() <= end
        let elapsed = Double((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)) / 1_000_000_000
        let mean = elapsed / Double(count)
        let diff = mean - baseLineMeanMs / 1000
        let b = "\(diff>0 ? "+" : "")\(diff.asSecondsPrettyPrint)"
        print("\(mean.asSecondsPrettyPrint.pad(8)) | \(min.asSecondsPrettyPrint.pad(8)) | \(max.asSecondsPrettyPrint.pad(8)) | \(String(count).pad(8)) | \(b.pad(16)) |")
        return result
    }
    
    /// `swift run -c release openmeteo-api benchmark`
    func run(using context: CommandContext, signature: Signature) throws {
        self.timePerTest = signature.time ?? 5
        
        print("| \("Test".pad(80)) | \("Mean".pad(8)) | \("Min".pad(8)) | \("Max".pad(8)) | \("Runs".pad(8)) | \("Diff to Apple M1".pad(16)) |")
        print("|\(String.dash(80+2))|\(String.dash(8+2))|\(String.dash(8+2))|\(String.dash(8+2))|\(String.dash(8+2))|\(String.dash(16+2))|")
        
        let sizeMb = 128
        let data = measure("Generating dummy temperature timeseries (\(sizeMb) MB)", 271) {
            return (0..<1024*1024/4*sizeMb).map({
                let x = Float($0)
                return sin(x * .pi / 24) * 10 + sin(x * .pi / 24 / 365.25) * 15 + sin(x * .pi / 7)
            })
        }
        
        try measure("Compression in memory, large chunks", 174) {
            try OmFileWriter(dim0: data.count / 1024, dim1: 1024, chunk0: 1024, chunk1: 1024).writeInMemory(compressionType: .p4nzdec256, scalefactor: 20, all: data)
        }
        
        let compressed = try measure("Compression in memory, small chunks", 179) {
            try OmFileWriter(dim0: data.count / 1024, dim1: 1024, chunk0: 8, chunk1: 128).writeInMemory(compressionType: .p4nzdec256, scalefactor: 20, all: data)
        }
        let sizeMbCompressed = (compressed.count/1024/1024)
        
        let compressedData = DataAsClass(data: compressed)
        _ = try measure("Decompress from memory, small chunks (\(sizeMbCompressed) MB)", 54) {
            try OmFileReader(fn: compressedData).readAll()
        }
        
        let file = "\(OpenMeteo.dataDictionary)test.om"
        try FileManager.default.createDirectory(atPath: OpenMeteo.dataDictionary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItemIfExists(at: file)}
        try measure("Compress to file, small chunks", 241) {
            try OmFileWriter(dim0: data.count / 1024, dim1: 1024, chunk0: 8, chunk1: 128).write(file: file, compressionType: .p4nzdec256, scalefactor: 20, all: data, overwrite: true)
        }
        
        try measure("Decompress from file, small chunks", 55) {
            let read = try OmFileReader(file: file)
            return try read.readAll()
        }
        
        
        let exradTime = TimerangeDt(start: Timestamp(1900,1,1), to: Timestamp(2000,1,1), dtSeconds: 3600)
        let exrad = measure("Calculate extra terrestrial radiation (100 years, hourly)", 46) {
            return Zensun.extraTerrestrialRadiationBackwards(latitude: 52, longitude: 7, timerange: exradTime)
        }
        
        _ = measure("Interpolate radiation to 15 minutes", 246) {
            let dtNew = exradTime.dtSeconds / 4
            let timeNew = exradTime.range.add(-exradTime.dtSeconds + dtNew).range(dtSeconds: dtNew)
            return exrad.interpolate(type: .solar_backwards_averaged, timeOld: exradTime, timeNew: timeNew, latitude: 52, longitude: 7, scalefactor: 100)
        }
    }
}
