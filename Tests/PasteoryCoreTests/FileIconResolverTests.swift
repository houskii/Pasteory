import Testing
@testable import PasteoryCore

@Test func fileIconCatalogContainsAllPackagedAssets() {
    #expect(FileIconResolver.allAssetNames.count == 49)
    #expect(Set(FileIconResolver.allAssetNames).count == 49)
}

@Test func fileIconResolverHandlesCommonAndClientDevelopmentFiles() {
    #expect(FileIconResolver.descriptor(fileName: "mac_lock_screen.txt").assetName == "txt")
    #expect(FileIconResolver.descriptor(fileName: "Screenshot.WEBP").assetName == "image")
    #expect(FileIconResolver.descriptor(fileName: "Feature.swift").assetName == "swift")
    #expect(FileIconResolver.descriptor(fileName: "MainActivity.kt").assetName == "kotlin")
    #expect(FileIconResolver.descriptor(fileName: "EntryAbility.ets").assetName == "arkts")
    #expect(FileIconResolver.descriptor(fileName: "release.apk").assetName == "android-package")
    #expect(FileIconResolver.descriptor(fileName: "release.hap").assetName == "harmony-package")
    #expect(FileIconResolver.descriptor(fileName: "Unknown.custom").assetName == "generic")
}

@Test func fileIconResolverPrioritizesExactNamesAndCompoundExtensions() {
    #expect(FileIconResolver.descriptor(fileName: "Makefile").assetName == "build")
    #expect(FileIconResolver.descriptor(fileName: "Package.swift").assetName == "swift")
    #expect(FileIconResolver.descriptor(fileName: "Podfile.lock").assetName == "lock")
    #expect(FileIconResolver.descriptor(fileName: ".gitignore").assetName == "git")
    #expect(FileIconResolver.descriptor(fileName: "diagnostics.tar.gz").assetName == "archive")
    #expect(FileIconResolver.descriptor(fileName: "capture.perfetto-trace").assetName == "diagnostic")
}

@Test func harUsesUTIToSeparateHarmonyPackageAndHTTPArchive() {
    #expect(FileIconResolver.descriptor(fileName: "network.har", uti: "public.json").assetName == "network")
    #expect(FileIconResolver.descriptor(fileName: "library.har", uti: "public.zip-archive").assetName == "harmony-package")
}

@Test func keyUsesUTIToSeparateKeynoteAndPrivateKeys() {
    #expect(FileIconResolver.descriptor(fileName: "slides.key", uti: "com.apple.iwork.keynote.key").assetName == "presentation")
    #expect(FileIconResolver.descriptor(fileName: "signing.key", uti: "public.data").assetName == "certificate")
}
