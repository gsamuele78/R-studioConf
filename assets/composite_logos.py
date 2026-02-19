
import os
from PIL import Image, ImageOps

def composite_images():
    # Paths
    assets_dir = "/home/jfs/00_Antigravity_workspace/R-studioConf/assets"
    background_path = "/home/jfs/.gemini/antigravity/brain/69576289-a501-4545-b192-e6e9c0850769/research_background_v1_1771249729803.png"
    
    logo1_path = os.path.join(assets_dir, "biome.png")
    logo2_path = os.path.join(assets_dir, "LW_ITA-1.png")
    output_path = "/home/jfs/.gemini/antigravity/brain/69576289-a501-4545-b192-e6e9c0850769/final_composite_layout.png"

    # Use the hardcoded background path
    if not os.path.exists(background_path):
        print(f"Error: Background file not found at {background_path}")
        return

    print(f"Using background: {background_path}")

    try:
        bg = Image.open(background_path).convert("RGBA")
        base_width, base_height = bg.size

        l1 = Image.open(logo1_path).convert("RGBA")
        l2 = Image.open(logo2_path).convert("RGBA")

        # Resize logos to fit nicely (e.g., each takes up 30-40% of width, or fit within a reasonable height)
        # Target height: 25% of background height
        target_h = int(base_height * 0.25)
        
        # Resize l1
        ratio1 = target_h / float(l1.size[1])
        w1 = int(float(l1.size[0]) * float(ratio1))
        l1 = l1.resize((w1, target_h), Image.Resampling.LANCZOS)

        # Resize l2
        ratio2 = target_h / float(l2.size[1])
        w2 = int(float(l2.size[0]) * float(ratio2))
        l2 = l2.resize((w2, target_h), Image.Resampling.LANCZOS)

        # Calculate positions (center horizontally, side by side with padding)
        padding = 50
        total_width = w1 + w2 + padding
        start_x = (base_width - total_width) // 2
        y_pos = (base_height - target_h) // 2

        # Paste with alpha
        bg.paste(l1, (start_x, y_pos), l1)
        bg.paste(l2, (start_x + w1 + padding, y_pos), l2)

        bg.save(output_path)
        print(f"Composite saved to {output_path}")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    composite_images()
