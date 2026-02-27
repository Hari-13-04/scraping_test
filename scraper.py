import time, json, re, pandas as pd, requests, argparse, os
from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

# ==========================================================
# ARGPARSE INPUT
# ==========================================================
parser = argparse.ArgumentParser(description="Sephora Product Scraper (Playwright)")
parser.add_argument("--input", required=True, help="Input Excel file path")
parser.add_argument("--output", required=False, help="Output Excel file path (optional)")
args = parser.parse_args()

input_file = args.input
headers = { 'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7', 'accept-language': 'en-GB,en-US;q=0.9,en;q=0.8,ta;q=0.7', 'priority': 'u=0, i', 'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"', 'sec-ch-ua-mobile': '?0', 'sec-ch-ua-platform': '"Windows"', 'sec-fetch-dest': 'document', 'sec-fetch-mode': 'navigate', 'sec-fetch-site': 'none', 'sec-fetch-user': '?1', 'upgrade-insecure-requests': '1', 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36'}
if args.output:
    output_file = args.output
else:
    base = os.path.splitext(os.path.basename(input_file))[0]
    output_file = base + "_output.xlsx"

input_df = pd.read_excel(input_file)

if "Product URL" not in input_df.columns:
    raise Exception("Excel must have a 'Product URL' column")

URL_LIST = input_df["Product URL"].tolist()

# ==========================================================
# PLAYWRIGHT SETUP
# ==========================================================
play = sync_playwright().start()
browser = play.chromium.launch(headless=False)
context = browser.new_context(
    user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/142.0.0.0 Safari/537.36",
    locale="en-US"
)
page = context.new_page()

# ==========================================================
# SCRAPER
# ==========================================================
def scrape_product(BASEURL):
    print("Scraping =>", BASEURL)
    url_collections = []
    try:
        page.goto(BASEURL, timeout=60000,wait_until="networkidle")
        page.wait_for_timeout(3000)


        # ---------- VARIANTS ----------
        try:
            buttons = page.query_selector_all('[data-comp="SwatchGroup "] button')
        except:
            buttons = None

        if buttons:
            for btn in buttons:
                variant_url = BASEURL

                data_at = btn.get_attribute("data-at") or ""

                if "selected" not in data_at:
                    html = btn.inner_html()
                    soup_btn = BeautifulSoup(html, "html.parser")

                    img_tag = soup_btn.select_one("img")

                    if img_tag and img_tag.get("src"):
                        sku_digits = re.findall(r"\d+", img_tag.get("src"))
                        if sku_digits:
                            variant_url = f"{BASEURL}?skuId={sku_digits[0]}"

                    else:
                        var_value = btn.get_attribute("aria-label")
                        page_html = page.content()

                        sku_match = None
                        if var_value:
                            sku_match = re.findall(
                                rf'displayName":"(\d+) {var_value}?","freeShippingMessage',
                                page_html
                            )
                            if not sku_match:
                                sku_match = re.findall(
                                    rf'displayName":"(\d+) {var_value}?","freeShippingType',
                                    page_html
                                )

                        if sku_match:
                            variant_url = f"{BASEURL}?skuId={sku_match[0]}"

                url_collections.append(variant_url)
        else:
            url_collections.append(BASEURL)
    except:
        None

    # ---------- SCRAPE VARIANTS ----------
    products = []

    for variant_url in url_collections:
        print("Variant =>", variant_url)
        page.goto(variant_url, timeout=60000)
        page.wait_for_timeout(4000)

        html = page.content()
        soup = BeautifulSoup(html, "html.parser")

        meta_title = soup.select_one("title").get_text(strip=True) if soup.select_one("title") else ""
        meta_desc = ""

        meta = soup.select_one('meta[name="description"]')
        if meta:
            meta_desc = meta.get("content", "")

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
        variant_nodes = soup.select('[data-at="sku_name_label"] span, [data-at="sku_size_label"]')

        v = 1
        for item in variant_nodes:
            txt = item.get_text(strip=True)

            if ":" in txt:
                name, val = txt.split(":", 1)
            elif txt.startswith("Size"):
                name, val = "Size", txt.replace("Size", "").strip()
            elif txt.startswith("Color"):
                name, val = "Color", txt.replace("Color", "").strip()
            else:
                continue

            var_dict[f"Variant Name {v}"] = name.strip()
            var_dict[f"Variant Value {v}"] = val.strip()
            v += 1

        # CATEGORY
        cat_dict = {}
        cats = soup.select('[aria-label="Breadcrumb"] li a')

        for idx, c in enumerate(cats, 1):
            txt = c.get_text(strip=True)
            link = c.get("href")
            link = link if link.startswith("http") else "https://www.sephora.com" + link

            cat_dict[f"Category Name {idx}"] = txt
            cat_dict[f"Category Link {idx}"] = link

        # IMAGES
        img_dict = {}
        imgs = soup.select('[data-at="product_images"] picture source')

        for i, tag in enumerate(imgs, 1):
            found = re.findall(r'https?://[^ ?]+', tag.get("srcset", ""))
            if found:
                img_dict[f"Image Name {i}"] = f"{sku}_{i}"
                img_dict[f"Image Link {i}"] = found[0]

        # HIGHLIGHTS
        block = re.search(r'"highlights":\s*\[([\s\S]*?)\],\s*"ingredientDesc"', html)
        highlights = ""
        if block:
            highlights = "\n".join(re.findall(r'"name":"(.*?)"', block.group(1)))

        # DESCRIPTION
        description = ""
        desc_raw = re.findall(
            r'\,\"longDescription\"\:.*\,\"longDescription\"\:\"(.*)?\"\,\"lovesCount"',
            html,
            flags=re.DOTALL
        )

        if desc_raw:
            parts = re.split(r'(?:<br\s*/?>\s*){2,}', desc_raw[0])
            for part in parts:
                txt = BeautifulSoup(part, "html.parser").get_text("\n", strip=True)
                description += txt + "\n"

        ingredient = soup.select_one('#ingredients div div')
        ingredient = ingredient.get_text("\n", strip=True) if ingredient else ""

        how_to = soup.select_one('[data-at="how_to_use_section"]')
        how_to_use = how_to.get_text("\n", strip=True) if how_to else ""

        products.append({
            "Product URL": variant_url,
            "SKU": sku,
            "Product Title": title,
            "Brand": brand,
            "Price": price,
            "Description": description.strip(),
            "Ingredient": ingredient,
            "How to Use": how_to_use,
            "Highlights": highlights,
            "Meta Title": meta_title,
            "Meta Description": meta_desc,
            **var_dict,
            **cat_dict,
            **img_dict
        })

    return products


# ==========================================================
# RUN
# ==========================================================
all_items = []
for i, url in enumerate(URL_LIST, 1):
    print(f"{i}/{len(URL_LIST)}")
    all_items.extend(scrape_product(url))


# ==========================================================
# BUILD EXCEL
# ==========================================================
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

    FINAL = FIXED + variant_headers + image_headers + category_headers

    df = pd.DataFrame(rows)
    df = df.reindex(columns=FINAL)
    df.to_excel(output_name, index=False)

    print("Saved:", output_name)


build_excel(all_items, output_file)

browser.close()
play.stop()

print("✅ Scraping completed")