import pathlib
p = pathlib.Path("NexusStore/Core/Catalog/SeedCatalog.swift")
s = p.read_text()
s = s.replace("""        #if SWIFT_PACKAGE
        let bundle: Bundle? = Bundle.module
        #else
        let bundle: Bundle? = Bundle.main
        #endif""", """        // `Bundle.module` only exists when the package declares resources; the iOS app embeds the
        // JSON through `SeedCatalog.games()` as well, so fall back to `Bundle.main`.
        let bundle: Bundle? = Bundle.main""")
p.write_text(s)
print("ok")
