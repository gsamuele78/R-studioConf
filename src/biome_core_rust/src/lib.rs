use std::fs;
use std::os::unix::ffi::OsStrExt;

#[no_mangle]
pub extern "C" fn biome_get_active_users(out_val: *mut i32) {
    let mut count = 0;
    
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            if let Ok(file_type) = entry.file_type() {
                if file_type.is_dir() {
                    let file_name = entry.file_name();
                    let name_bytes = file_name.as_bytes();
                    
                    if !name_bytes.is_empty() && name_bytes.iter().all(|c| c.is_ascii_digit()) {
                        let mut path_buf = [0u8; 64]; // Max length: /proc/PID/cmdline\0
                        let total_len = 6 + name_bytes.len() + 9;
                        if total_len <= path_buf.len() {
                            path_buf[..6].copy_from_slice(b"/proc/");
                            path_buf[6..6+name_bytes.len()].copy_from_slice(name_bytes);
                            path_buf[6+name_bytes.len()..total_len].copy_from_slice(b"/cmdline\0");
                            
                            unsafe {
                                let fd = libc::open(path_buf.as_ptr() as *const libc::c_char, libc::O_RDONLY);
                                if fd >= 0 {
                                    let mut buf = [0u8; 1024];
                                    let n = libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
                                    if n >= 8 {
                                        let window = &buf[..n as usize];
                                        if window.windows(8).any(|w| w == b"rsession") {
                                            count += 1;
                                        }
                                    }
                                    libc::close(fd);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    unsafe {
        *out_val = if count == 0 { 1 } else { count };
    }
}

#[no_mangle]
pub extern "C" fn biome_get_system_ram_gb(out_val: *mut f64) {
    let mut kb_available = 0.0;
    
    unsafe {
        let fd = libc::open(b"/proc/meminfo\0".as_ptr() as *const libc::c_char, libc::O_RDONLY);
        if fd >= 0 {
            let mut buf = [0u8; 4096];
            let n = libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
            if n > 0 {
                let s = &buf[..n as usize];
                
                fn find_kb(s: &[u8], needle: &[u8]) -> Option<f64> {
                    if let Some(pos) = s.windows(needle.len()).position(|w| w == needle) {
                        let mut end = pos + needle.len();
                        while end < s.len() && (s[end] == b' ' || s[end] == b'\t') {
                            end += 1;
                        }
                        let mut num_end = end;
                        while num_end < s.len() && s[num_end].is_ascii_digit() {
                            num_end += 1;
                        }
                        if num_end > end {
                            if let Ok(num_str) = std::str::from_utf8(&s[end..num_end]) {
                                return num_str.parse::<f64>().ok();
                            }
                        }
                    }
                    None
                }
                
                if let Some(av) = find_kb(s, b"\nMemAvailable:") {
                    kb_available = av;
                } else if let Some(av) = find_kb(s, b"MemAvailable:") { 
                    kb_available = av;
                } else {
                    let mem_free = find_kb(s, b"\nMemFree:").unwrap_or(0.0);
                    let buffers = find_kb(s, b"\nBuffers:").unwrap_or(0.0);
                    let cached = find_kb(s, b"\nCached:").unwrap_or(0.0);
                    kb_available = mem_free + buffers + cached;
                }
            }
            libc::close(fd);
        }
    }
    
    unsafe {
        *out_val = if kb_available > 0.0 {
            kb_available / 1024.0 / 1024.0
        } else {
            16.0
        };
    }
}

#[no_mangle]
pub extern "C" fn biome_get_tmp_use_pct(out_val: *mut f64) {
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    
    unsafe {
        if libc::statvfs(b"/tmp\0".as_ptr() as *const libc::c_char, &mut stat) == 0 {
            if stat.f_blocks > 0 {
                let used = stat.f_blocks.saturating_sub(stat.f_bfree);
                *out_val = (used as f64 / stat.f_blocks as f64) * 100.0;
                return;
            }
        }
        *out_val = 0.0;
    }
}
