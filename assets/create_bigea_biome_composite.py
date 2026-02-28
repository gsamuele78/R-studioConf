import os
from PIL import Image, ImageOps, ImageFilter

def add_glow(img, color="white", radius=15):
    """Adds a glow effect to an image."""
    mask = img.split()[3]
    glow = Image.new("RGBA", img.size, color)
    glow.putalpha(mask)
    glow = glow.filter(ImageFilter.GaussianBlur(radius))
    return glow

def composite_images_transparent():
    assets_dir = "/home/jfs/00_Antigravity_workspace/R-studioConf/assets"
    logo1_path = os.path.join(assets_dir, "Bigea.png")
    logo2_path = os.path.join(assets_dir, "biome.png")
    
    output_path = os.path.join(assets_dir, "composite_bigea_biome_glow_transparent.png")
    output_path_white = os.path.join(assets_dir, "composite_bigea_biome_glow_white.png")

    try:
        l1 = Image.open(logo1_path).convert("RGBA")
        l2 = Image.open(logo2_path).convert("RGBA")

        target_h = 300

        # Resize l1
        ratio1 = target_h / float(l1.size[1])
        w1 = int(float(l1.size[0]) * float(ratio1))
        l1 = l1.resize((w1, target_h), Image.Resampling.LANCZOS)

        # Resize l2
        ratio2 = target_h / float(l2.size[1])
        w2 = int(float(l2.size[0]) * float(ratio2))
        l2 = l2.resize((w2, target_h), Image.Resampling.LANCZOS)

        # Padding between logos
        padding = 100
        total_width = w1 + w2 + padding
        
        # Create transparent background
        margin = 50
        bg_width = total_width + (margin * 2)
        bg_height = target_h + (margin * 2)
        
        bg = Image.new("RGBA", (bg_width, bg_height), (0, 0, 0, 0))

        def paste_with_glow(base_img, src_img, x, y):
            glow = add_glow(src_img, color=(255, 255, 255, 180), radius=20)
            base_img.paste(glow, (x, y), glow)
            base_img.paste(src_img, (x, y), src_img)

        # Position 1
        x1 = margin
        y1 = margin
        paste_with_glow(bg, l1, x1, y1)

        # Position 2
        x2 = margin + w1 + padding
        y2 = margin
        paste_with_glow(bg, l2, x2, y2)

        bg.save(output_path)
        print(f"Transparent composite saved to {output_path}")

        # Create white background version
        bg_white = Image.new("RGBA", (bg_width, bg_height), "white")
        bg_white.paste(l1, (x1, y1), l1)
        bg_white.paste(l2, (x2, y2), l2)
        
        bg_white.save(output_path_white)
        print(f"White background composite saved to {output_path_white}")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    composite_images_transparent()
