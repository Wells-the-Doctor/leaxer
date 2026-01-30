fn main() {
    tauri_build::build();

    // Copy WebView2Loader.dll to the output directory
    // The webview2-com-sys crate builds it but doesn't copy it to the final location
    #[cfg(windows)]
    {
        use std::env;
        use std::path::Path;

        let out_dir = env::var("OUT_DIR").unwrap();
        let profile = env::var("PROFILE").unwrap();

        // Find the WebView2Loader.dll in the build output
        let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
        let target_dir = Path::new(&manifest_dir).join("target").join(&profile);

        // Source: built by webview2-com-sys
        let src_dll = Path::new(&out_dir)
            .ancestors()
            .find(|p| p.file_name().map(|n| n.to_str().unwrap_or("").starts_with("webview2-com-sys")).unwrap_or(false))
            .map(|p| p.join("out").join("x64").join("WebView2Loader.dll"));

        if let Some(src) = src_dll {
            if src.exists() {
                let dest = target_dir.join("WebView2Loader.dll");
                if let Err(e) = std::fs::copy(&src, &dest) {
                    println!("cargo:warning=Failed to copy WebView2Loader.dll: {}", e);
                } else {
                    println!("cargo:warning=Copied WebView2Loader.dll to {:?}", dest);
                }
            }
        }
    }
}
