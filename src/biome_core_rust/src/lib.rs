use std::fs;
use std::io::Read;

#[no_mangle]
pub extern "C" fn biome_get_active_users(out_val: *mut i32) {
    let fallback = 1;
    let mut count = 0;

    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            if let Ok(file_type) = entry.file_type() {
                if file_type.is_dir() {
                    let file_name = entry.file_name();
                    let name_str = file_name.to_string_lossy();
                    if name_str.chars().all(|c| c.is_ascii_digit()) {
                        let cmd_path = entry.path().join("cmdline");
                        if let Ok(mut file) = fs::File::open(&cmd_path) {
                            let mut raw_buf = Vec::new();
                            if file.read_to_end(&mut raw_buf).is_ok() {
                                let cmdline = String::from_utf8_lossy(&raw_buf);
                                if cmdline.contains("rsession") {
                                    count += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    unsafe {
        if count == 0 {
            *out_val = fallback;
        } else {
            *out_val = count;
        }
    }
}

#[no_mangle]
pub extern "C" fn biome_get_system_ram_gb(out_val: *mut f64) {
    let fallback = 16.0;
    
    if let Ok(contents) = fs::read_to_string("/proc/meminfo") {
        let mut mem_available: Option<f64> = None;
        let mut mem_free: Option<f64> = None;
        let mut buffers: Option<f64> = None;
        let mut cached: Option<f64> = None;

        for line in contents.lines() {
            if line.starts_with("MemAvailable:") {
                if let Some(val_str) = line.split_whitespace().nth(1) {
                    mem_available = val_str.parse::<f64>().ok();
                }
            } else if line.starts_with("MemFree:") {
                if let Some(val_str) = line.split_whitespace().nth(1) {
                    mem_free = val_str.parse::<f64>().ok();
                }
            } else if line.starts_with("Buffers:") {
                if let Some(val_str) = line.split_whitespace().nth(1) {
                    buffers = val_str.parse::<f64>().ok();
                }
            } else if line.starts_with("Cached:") {
                if let Some(val_str) = line.split_whitespace().nth(1) {
                    cached = val_str.parse::<f64>().ok();
                }
            }
        }

        let kb = if let Some(av) = mem_available {
            av
        } else {
            mem_free.unwrap_or(0.0) + buffers.unwrap_or(0.0) + cached.unwrap_or(0.0)
        };

        if kb > 0.0 {
            unsafe { *out_val = kb / 1024.0 / 1024.0 };
            return;
        }
    }
    
    unsafe { *out_val = fallback };
}

#[no_mangle]
pub extern "C" fn biome_get_tmp_use_pct(out_val: *mut f64) {
    let fallback = 0.0;
    
    let path = std::ffi::CString::new("/tmp").unwrap_or_default();
    if path.as_bytes().is_empty() {
        unsafe { *out_val = fallback; }
        return;
    }

    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    
    unsafe {
        if libc::statvfs(path.as_ptr(), &mut stat) == 0 {
            if stat.f_blocks > 0 {
                let used = stat.f_blocks.saturating_sub(stat.f_bfree);
                let pct = (used as f64 / stat.f_blocks as f64) * 100.0;
                *out_val = pct;
                return;
            }
        }
        *out_val = fallback;
    }
}
