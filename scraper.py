headers = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  'accept-language': 'en-GB,en-US;q=0.9,en;q=0.8,ta;q=0.7',
  'priority': 'u=0, i',
  'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"Windows"',
  'sec-fetch-dest': 'document',
  'sec-fetch-mode': 'navigate',
  'sec-fetch-site': 'none',
  'sec-fetch-user': '?1',
  'upgrade-insecure-requests': '1',
  'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
}

import time, json, re, pandas as pd, requests, argparse, os
from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth

# ============================
# Args
# ============================
parser = argparse.ArgumentParser(description="Sephora Product Scraper")
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=False)
args = parser.parse_args()

input_file = args.input
output_file = args.output or os.path.splitext(os.path.basename(input_file))[0] + "_output.xlsx"

df = pd.read_excel(input_file)
if "Product URL" not in df.columns:
    raise Exception("Excel must have Product URL column")

URL_LIST = df["Product URL"].tolist()

# ============================
# Playwright setup
# ============================
play = sync_playwright().start()
browser = play.chromium.launch(headless=False, args=[
        "--disable-blink-features=AutomationControlled",
        "--no-sandbox",
        "--disable-dev-shm-usage"
    ])
context = browser.new_context(
    user_agent=headers["user-agent"],
    viewport={"width": 1920, "height": 1080}
)
page = context.new_page()
stealth.stealth_sync(page)

# ============================
# Scrape function
# ============================
def scrape_product(BASEURL):
    print("Scraping =>", BASEURL)

    page.goto(BASEURL, timeout=60000, wait_until="domcontentloaded")
    page.wait_for_timeout(3000)

    html = page.content()
    soup = BeautifulSoup(html, "html.parser")

    # -------- VARIANTS --------
    try:
        buttons = page.query_selector_all('[data-comp="SwatchGroup "] button')
    except:
        print("No swatch groups")
        buttons = []
    url_collections = []

    if buttons:
        for button in buttons:
            variant_url = BASEURL
            html_btn = button.inner_html()

            data_at = button.get_attribute("data-at") or ""
            if "selected" not in data_at:
                soup_btn = BeautifulSoup(html_btn, "html.parser")
                img_tag = soup_btn.select_one("img")

                if img_tag and img_tag.get("src"):
                    digits = re.findall(r"\d+", img_tag["src"])
                    if digits:
                        variant_url = f"{BASEURL}?skuId={digits[0]}"

                else:
                    aria = button.get_attribute("aria-label")
                    page_html = page.content()

                    sku_match = None
                    if aria:
                        sku_match = re.findall(rf'displayName":"(\d+) {aria}?","freeShippingMessage', page_html)
                        if not sku_match:
                            sku_match = re.findall(rf'displayName":"(\d+) {aria}?","freeShippingType', page_html)

                    if sku_match:
                        variant_url = f"{BASEURL}?skuId={sku_match[0]}"

            url_collections.append(variant_url)
    else:
        url_collections.append(BASEURL)

    products = []

    # -------- EACH VARIANT --------
    for vurl in url_collections:
        print(vurl)
        page.goto(vurl, timeout=60000)
        page.wait_for_timeout(5000)

        html = page.content()
        soup = BeautifulSoup(html, "html.parser")

        meta_title = soup.title.get_text(strip=True) if soup.title else ""
        meta_desc = ""
        meta = soup.select_one('meta[name="description"]')
        if meta:
            meta_desc = meta.get("content", "")
        else:
            r = requests.get(vurl, headers=headers)
            m = BeautifulSoup(r.text, "html.parser").select_one('meta[name="description"]')
            if m:
                meta_desc = m.get("content", "")

        # BASIC
        title = soup.select_one('[data-at="product_name"]')
        title = title.get_text(strip=True) if title else ""

        sku = soup.select_one('[data-at="item_sku"]')
        sku = sku.get_text(strip=True).replace("Item ", "") if sku else ""

        brand = soup.select_one('[data-at="brand_name"]')
        brand = brand.get_text(strip=True) if brand else ""

        price = soup.select_one('b.css-0')
        price = price.get_text(strip=True) if price else ""

        # VARIANTS
        var_dict = {}
        nodes = soup.select('[data-at="sku_name_label"] span, [data-at="sku_size_label"]')
        v = 1
        for item in nodes:
            txt = item.get_text(strip=True)
            if ":" in txt:
                name, val = txt.split(":", 1)
            elif txt.startswith("Size"):
                name, val = "Size", txt.replace("Size", "").strip()
            elif txt.startswith("Color"):
                name, val = "Color", txt.replace("Color", "").strip()
            else:
                continue

            var_dict[f"Variant Name {v}"] = name
            var_dict[f"Variant Value {v}"] = val
            v += 1

        # CATEGORY
        cat_dict = {}
        cats = soup.select('[aria-label="Breadcrumb"] li a')
        for i, c in enumerate(cats, 1):
            name = c.get_text(strip=True)
            link = c.get("href")
            if link and not link.startswith("http"):
                link = "https://www.sephora.com" + link
            cat_dict[f"Category Name {i}"] = name
            cat_dict[f"Category Link {i}"] = link

        # IMAGES
        img_dict = {}
        imgs = soup.select('[data-at="product_images"] picture source')
        for i, tag in enumerate(imgs, 1):
            found = re.findall(r'https?://[^ ?]+', tag.get("srcset", ""))
            if found:
                img_dict[f"Image Name {i}"] = f"{sku}_{i}"
                img_dict[f"Image Link {i}"] = found[0]

        # HIGHLIGHTS
        highlights = ""
        block = re.search(r'"highlights":\s*\[([\s\S]*?)\],\s*"ingredientDesc"', html)
        if block:
            highlights = "\n".join(re.findall(r'"name":"(.*?)"', block.group(1)))

        # DESCRIPTION
        description = ""
        desc_raw = re.findall(r'\,\"longDescription\"\:.*\,\"longDescription\"\:\"(.*)?\"\,\"lovesCount"', html, re.DOTALL)
        if desc_raw:
            parts = re.split(r'(?:<br\s*/?>\s*){2,}', desc_raw[0])
            for part in parts:
                txt = BeautifulSoup(part, "html.parser").get_text("\n", strip=True)
                lines = txt.split("\n")
                cleaned = " ".join(lines) if len(lines) <= 2 else txt
                description += cleaned + "\n"

        ingredient = soup.select_one('#ingredients div div')
        ingredient = ingredient.get_text("\n", strip=True) if ingredient else ""

        how_to = soup.select_one('[data-at="how_to_use_section"]')
        how_to = how_to.get_text("\n", strip=True) if how_to else ""

        products.append({
            "Product URL": vurl,
            "SKU": sku,
            "Product Title": title,
            "Brand": brand,
            "Price": price,
            "Description": description.strip(),
            "Ingredient": ingredient,
            "How to Use": how_to,
            "Highlights": highlights,
            "Meta Title": meta_title,
            "Meta Description": meta_desc,
            **var_dict,
            **cat_dict,
            **img_dict
        })

    return products


# ============================
# RUN ALL
# ============================
all_items = []
for i, url in enumerate(URL_LIST, 1):
    print(f"{i}/{len(URL_LIST)}")
    all_items.extend(scrape_product(url))


# ============================
# BUILD EXCEL
# ============================
def build_excel(rows, output_name):
    FIXED = [
        "Product URL","SKU","Product Title","Brand",
        "Price","Description","Ingredient","How to Use",
        "Highlights","Meta Title","Meta Description"
    ]

    variant_headers, image_headers, category_headers = [], [], []

    for item in rows:
        for k in item.keys():
            if "Variant" in k and k not in variant_headers:
                variant_headers.append(k)
            if "Image" in k and k not in image_headers:
                image_headers.append(k)
            if "Category" in k and k not in category_headers:
                category_headers.append(k)

    variant_headers = sorted(variant_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))
    image_headers = sorted(image_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))
    category_headers = sorted(category_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))

    cols = FIXED + variant_headers + image_headers + category_headers
    df = pd.DataFrame(rows).reindex(columns=cols)
    df.to_excel(output_name, index=False)
    print("Saved:", output_name)


build_excel(all_items, output_file)

browser.close()
play.stop()
print("Scraping completed successfully!")
