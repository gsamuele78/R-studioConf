#!/usr/bin/env python3
import sys
import argparse
import json
from src.utils.logger import logger
from src.detectors.auth_backend import AuthBackendDetector
from src.managers.backup_manager import BackupManager

def main():
    parser = argparse.ArgumentParser(description="Next-Gen R-Studio Configuration Manager")
    parser.add_argument("--detect-backend", action="store_true", help="Detect active authentication backend")
    parser.add_argument("--backup", action="store_true", help="Perform system configuration backup")
    args = parser.parse_args()

    logger.info("Next-Gen Manager initialized.")

    if args.detect_backend:
        detector = AuthBackendDetector()
        result = detector.get_details()
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if args.backup:
        manager = BackupManager()
        if manager.perform_backup():
            logger.info("Backup completed successfully.")
            sys.exit(0)
        else:
            logger.error("Backup failed.")
            sys.exit(1)
    
    logger.info("No action specified. Use --help.")

if __name__ == "__main__":
    main()
