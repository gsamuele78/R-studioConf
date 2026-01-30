import os
from enum import Enum
from typing import Dict, Any
from ..utils.shell import is_service_active
from ..utils.logger import logger

class AuthBackend(Enum):
    SSSD = "SSSD"
    SAMBA = "SAMBA"
    NONE = "NONE"

class AuthBackendDetector:
    """
    Detects the active authentication backend (SSSD vs SAMBA).
    Ports logic from scripts/30_install_nginx.sh
    """
    
    @staticmethod
    def detect() -> AuthBackend:
        logger.info("Starting authentication backend detection...")
        
        # 1. Check Service Status (Most reliable)
        if is_service_active('sssd'):
            logger.info("Detection: SSSD service is active.")
            return AuthBackend.SSSD
            
        if is_service_active('winbind') or is_service_active('smbd'):
            logger.info("Detection: Samba/Winbind services are active.")
            return AuthBackend.SAMBA

        # 2. Check Configuration Files
        if os.path.isfile('/etc/sssd/sssd.conf'):
            logger.info("Detection: sssd.conf found.")
            return AuthBackend.SSSD
            
        if os.path.isfile('/etc/samba/smb.conf'):
            logger.info("Detection: smb.conf found.")
            return AuthBackend.SAMBA
            
        # 3. Check nsswitch.conf (Deep check)
        try:
            with open('/etc/nsswitch.conf', 'r') as f:
                content = f.read()
                if 'sss' in content:
                    logger.info("Detection: 'sss' found in nsswitch.conf")
                    return AuthBackend.SSSD
                if 'winbind' in content:
                    logger.info("Detection: 'winbind' found in nsswitch.conf")
                    return AuthBackend.SAMBA
        except FileNotFoundError:
            pass
            
        logger.warn("No active authentication backend detected.")
        return AuthBackend.NONE

    def get_details(self) -> Dict[str, Any]:
        """Returns details about the detected backend for Ansible verification."""
        backend = self.detect()
        return {
            "backend": backend.value,
            "is_domain_joined": backend != AuthBackend.NONE
        }
