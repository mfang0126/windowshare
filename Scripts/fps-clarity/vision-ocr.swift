import Foundation
import Vision
import AppKit
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let request=VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages=["en-US","zh-Hans"]; request.usesLanguageCorrection=false
try VNImageRequestHandler(url:url).perform([request])
for o in request.results ?? [] { if let c=o.topCandidates(1).first { print(c.string) } }
