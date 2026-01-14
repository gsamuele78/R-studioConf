import logging
import sys
import json
from datetime import datetime
from typing import Optional, Dict

class UnifiedLogger:
    """
    Unified Logger for Next-Gen R-studioConf components.
    Ports functionality from legacy common_utils.sh 'log' function.
    Supports structured JSON logging and human-readable console output.
    """
    
    LEVEL_MAP = {
        "DEBUG": logging.DEBUG,
        "INFO": logging.INFO,
        "WARN": logging.WARNING,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
        "FATAL": logging.CRITICAL
    }

    def __init__(self, name: str = "next_gen", log_file: Optional[str] = "/var/log/r_env_manager/next_gen.log"):
        self.logger = logging.getLogger(name)
        self.logger.setLevel(logging.DEBUG)
        self.logger.propagate = False
        
        formatter = logging.Formatter(
            '%(asctime)s - %(levelname)-5s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )

        # Console Handler (Stdout)
        ch = logging.StreamHandler(sys.stdout)
        ch.setLevel(logging.INFO)
        ch.setFormatter(formatter)
        self.logger.addHandler(ch)

        # File Handler
        if log_file:
            try:
                fh = logging.FileHandler(log_file)
                fh.setLevel(logging.DEBUG)
                fh.setFormatter(formatter)
                self.logger.addHandler(fh)
            except PermissionError:
                # Fallback if no permission to write to /var/log
                sys.stderr.write(f"WARN: Could not write to log file {log_file}. Logging to console only.\n")

    def log(self, level: str, message: str, extra: Optional[Dict] = None):
        """
        Log a message with a specific level.
        Args:
            level: INFO, WARN, ERROR, FATAL, DEBUG
            message: The content of the log
            extra: Dictionary of extra structured data for future JSON logging support
        """
        lvl = self.LEVEL_MAP.get(level.upper(), logging.INFO)
        
        # In the future, we can dump 'extra' as JSON strings if needed
        # for now, we stick to the textual format of the legacy system
        if extra:
            message = f"{message} | context={json.dumps(extra)}"
            
        self.logger.log(lvl, message)

    def info(self, msg: str): self.log("INFO", msg)
    def warn(self, msg: str): self.log("WARN", msg)
    def error(self, msg: str): self.log("ERROR", msg)
    def fatal(self, msg: str): self.log("FATAL", msg)
    def debug(self, msg: str): self.log("DEBUG", msg)

# Singleton instance for easy import
logger = UnifiedLogger()
