import subprocess
import logging
from typing import Tuple, List, Optional
from .logger import logger

class ShellCommandError(Exception):
    pass

def run_command(command: List[str], check: bool = False, capture_output: bool = True, timeout: Optional[int] = None) -> subprocess.CompletedProcess:
    """
    Execute a shell command with logging.
    
    Args:
        command: List of command parts (e.g. ['ls', '-l'])
        check: If True, raise ShellCommandError on non-zero exit code
        capture_output: If True, capture stdout/stderr
        timeout: Timeout in seconds
        
    Returns:
        subprocess.CompletedProcess object
    """
    cmd_str = " ".join(command)
    logger.debug(f"Executing: {cmd_str}")
    
    try:
        result = subprocess.run(
            command,
            check=check,
            capture_output=capture_output,
            text=True,
            timeout=timeout
        )
        if result.returncode == 0:
            logger.debug(f"Command succeeded: {cmd_str}")
        else:
            logger.debug(f"Command failed (code {result.returncode}): {cmd_str}")
            
        return result
        
    except subprocess.CalledProcessError as e:
        logger.error(f"Command failed with error: {e}")
        if capture_output:
            logger.error(f"Stderr: {e.stderr}")
        raise ShellCommandError(f"Command '{cmd_str}' failed") from e
    except Exception as e:
        logger.error(f"Execution error for '{cmd_str}': {e}")
        raise

def is_service_active(service_name: str) -> bool:
    """Check if a systemd service is active."""
    try:
        res = run_command(['systemctl', 'is-active', '-q', service_name], check=False)
        return res.returncode == 0
    except Exception:
        return False
