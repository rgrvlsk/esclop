// SPDX-License-Identifier: GPL-3.0-or-later

@testable import EsclopAppKit
import Foundation
import Testing

/// SigV4 against the examples in AWS's S3 documentation ("Signature Calculations for the
/// Authorization Header"), whose keys and signatures are published there.
@Suite struct S3SignerTests {
    static let accessKey = "AKIAIOSFODNN7EXAMPLE"
    static let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    static let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    @Test func getObjectMatchesAWSsExample() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let headers = S3Signer.sign(
            method: "GET", url: url, headers: ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            accessKey: Self.accessKey, secret: Self.secret, region: "us-east-1", date: Self.date
        )
        #expect(headers["x-amz-date"] == "20130524T000000Z")
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func putObjectMatchesAWSsExample() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/" + S3Signer.encode("test$file.text", keepSlashes: true))!
        let headers = S3Signer.sign(
            method: "PUT", url: url,
            headers: ["host": "examplebucket.s3.amazonaws.com", "date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
            payloadHash: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
            accessKey: Self.accessKey, secret: Self.secret, region: "us-east-1", date: Self.date
        )
        #expect(headers["Authorization"]?.hasSuffix("SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd") == true)
    }

    @Test func keysAreEncodedOnceWithSlashesKept() {
        #expect(S3Signer.encode("2026/11/a b+ç.png", keepSlashes: true) == "2026/11/a%20b%2B%C3%A7.png")
        #expect(S3Signer.encode("a/b") == "a%2Fb")
        #expect(S3Signer.hostHeader(URL(string: "http://127.0.0.1:9000/x")!) == "127.0.0.1:9000")
        #expect(S3Signer.hostHeader(URL(string: "https://s3.amazonaws.com:443/x")!) == "s3.amazonaws.com")
    }
}
