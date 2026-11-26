//
//  CertFlowTests.swift
//  CertFlowTests
//
//  Created by GAO on 2026/6/15.
//

import Testing
@testable import CertFlow

struct CertFlowTests {

    @Test func openSSL3NeedsLegacy() {
        #expect(Converter.needsLegacyProvider(versionOutput: "OpenSSL 3.6.2 1 Oct 2025 (Library: OpenSSL 3.6.2 1 Oct 2025)"))
    }

    @Test func openSSL4NeedsLegacy() {
        #expect(Converter.needsLegacyProvider(versionOutput: "OpenSSL 4.0.3 29 Sep 2026 (Library: OpenSSL 4.0.3 29 Sep 2026)"))
    }

    @Test func openSSL11DoesNotNeedLegacy() {
        #expect(!Converter.needsLegacyProvider(versionOutput: "OpenSSL 1.1.1w 11 Sep 2023"))
    }

    @Test func libreSSLDoesNotNeedLegacy() {
        #expect(!Converter.needsLegacyProvider(versionOutput: "LibreSSL 3.3.6"))
    }

    @Test func unknownOutputDoesNotNeedLegacy() {
        #expect(!Converter.needsLegacyProvider(versionOutput: ""))
        #expect(!Converter.needsLegacyProvider(versionOutput: "something unexpected"))
    }

}
