import os
import shutil
import glob
from datetime import datetime
from typing import List
from ..utils.logger import logger

class BackupManager:
    """
    Manages configuration backups.
    Ports logic from legacy common_utils.sh 'backup_config' function.
    """
    
    BACKUP_BASE_DIR = "/var/backups/r_env_manager"
    
    # List of critical paths to backup
    TARGETS = [
        "/etc/nginx/sites-available",
        "/etc/nginx/nginx.conf",
        "/etc/rstudio/rserver.conf",
        "/etc/rstudio/rsession.conf",
        "/etc/R/Rprofile.site",
        "/etc/sssd/sssd.conf",
        "/etc/krb5.conf",
        "/etc/pam.d"
    ]

    def __init__(self):
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.backup_dir = os.path.join(self.BACKUP_BASE_DIR, f"backup_{self.timestamp}")

    def perform_backup(self) -> bool:
        """
        Executes the backup process.
        Returns: True if successful (partial or full), False if critical failure.
        """
        logger.info(f"Starting backup process. Destination: {self.backup_dir}")
        
        try:
            os.makedirs(self.backup_dir, exist_ok=True)
        except OSError as e:
            logger.fatal(f"Could not create backup directory: {e}")
            return False

        success_count = 0
        
        for target in self.TARGETS:
            if not os.path.exists(target):
                logger.debug(f"Skipping {target}: Path does not exist.")
                continue
                
            # Preserve hierarchy: /etc/nginx/nginx.conf -> <backup_dir>/etc/nginx/nginx.conf
            # We strip the leading '/' to append correctly
            rel_path = target.lstrip('/')
            dest_path = os.path.join(self.backup_dir, rel_path)
            dest_parent = os.path.dirname(dest_path)
            
            try:
                os.makedirs(dest_parent, exist_ok=True)
                
                if os.path.isdir(target):
                    shutil.copytree(target, dest_path, dirs_exist_ok=True)
                    logger.debug(f"Backed up directory: {target}")
                else:
                    shutil.copy2(target, dest_path)
                    logger.debug(f"Backed up file: {target}")
                
                success_count += 1
            except Exception as e:
                logger.error(f"Failed to backup {target}: {e}")
        
        if success_count > 0:
            logger.info(f"Backup operation finished. {success_count} items secured.")
            self._rotate_old_backups()
            return True
        else:
            logger.warn("Backup finished but no files were found/copied.")
            return True

    def _rotate_old_backups(self, retention_count: int = 5):
        """Keeps only the last N backups."""
        try:
            # Find all backup directories
            pattern = os.path.join(self.BACKUP_BASE_DIR, "backup_*")
            backups = sorted(glob.glob(pattern))
            
            if len(backups) > retention_count:
                to_delete = backups[:-retention_count]
                for old_bd in to_delete:
                    logger.info(f"Rotating old backup: {old_bd}")
                    shutil.rmtree(old_bd)
        except Exception as e:
            logger.error(f"Error rotating backups: {e}")
