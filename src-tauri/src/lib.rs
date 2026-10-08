// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // Sign-in comes back from the browser as a deep link. The Android intent
        // filter is generated from `plugins.deep-link` in tauri.conf.json when
        // the CLI builds for Android, so no manifest is edited by hand.
        .plugin(tauri_plugin_deep_link::init());

    // Bluetooth provisioning: the frontend scans for the vase and hands it the
    // home Wi-Fi credentials. Skipping the plugin keeps the app usable on a
    // machine with no usable BLE adapter.
    let builder = match tauri_plugin_blec::try_init() {
        Ok(plugin) => builder.plugin(plugin),
        Err(error) => {
            eprintln!("Bluetooth indisponível: {error:?}");
            builder
        }
    };

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
