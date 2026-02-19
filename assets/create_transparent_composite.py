import os
from PIL import Image, ImageOps, ImageFilter

def add_glow(img, color="white", radius=15):
    """Adds a glow effect to an image."""
    # Create a mask of the image's alpha channel
    mask = img.split()[3]
    
    # Create a blurred version of the mask to simulate glow
    glow = Image.new("RGBA", img.size, color)
    glow.putalpha(mask)
    glow = glow.filter(ImageFilter.GaussianBlur(radius))
    
    # Composite the original image over the glow
    # Expand canvas to fit glow if necessary? For now, we assume simple composition.
    # Actually, to do this right, we might need a larger canvas, but let's try compositing directly if there's space.
    # Since we are placing it on a new transparent background, we can just paste the glow then the image.
    return glow

def composite_images_transparent():
    assets_dir = "/home/jfs/00_Antigravity_workspace/R-studioConf/assets"
    logo1_path = os.path.join(assets_dir, "biome.png")
    logo2_path = os.path.join(assets_dir, "LW_ITA-1.png")
    output_path = os.path.join(assets_dir, "composite_logo_transparent.png")

    try:
        l1 = Image.open(logo1_path).convert("RGBA")
        l2 = Image.open(logo2_path).convert("RGBA")

        # Determine target height (e.g., 200px or based on some ratio)
        target_h = 300 # A reasonable high-res height

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
        # Add some extra margin for the glow effect
        margin = 50
        bg_width = total_width + (margin * 2)
        bg_height = target_h + (margin * 2)
        
        bg = Image.new("RGBA", (bg_width, bg_height), (0, 0, 0, 0))

        # Create glow versions
        # We'll create a simple white drop-shadow/glow for visibility on dark backgrounds
        # given the user mentioned "final_composite_layout.png have to be visible wwhen a web page is loaded with assets/background.png backgroung"
        # Assuming background.png is dark/complex.
        
        # Helper to paste centered
        def paste_with_glow(base_img, src_img, x, y):
            # Create glow
            glow = add_glow(src_img, color=(255, 255, 255, 180), radius=20)
            
            # Paste glow
            base_img.paste(glow, (x, y), glow)
            # Paste original
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
        
        # Paste logos directly (without white glow)
        bg_white.paste(l1, (x1, y1), l1)
        bg_white.paste(l2, (x2, y2), l2)
        
        output_path_white = os.path.join(assets_dir, "composite_logo_white.png")
        bg_white.save(output_path_white)
        print(f"White background composite saved to {output_path_white}")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    composite_images_transparent()
