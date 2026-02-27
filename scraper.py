import time, json,re, pandas as pd,requests,argparse,os
from bs4 import BeautifulSoup
from seleniumbase import Driver
from selenium_stealth import stealth
from selenium.webdriver.common.by import By
from selenium.webdriver.support.wait import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

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

# ==========================================================
# Ask user for input Excel
# ==========================================================

parser = argparse.ArgumentParser(description="Sephora Product Scraper")
parser.add_argument("--input", required=True, help="Input Excel file path")
parser.add_argument("--output", required=False, help="Output Excel file path (optional)")
args = parser.parse_args()

input_file = args.input

# Set output filename
if args.output:
    output_file = args.output
else:
    base = os.path.splitext(os.path.basename(input_file))[0]
    output_file = base + "_output.xlsx"

input_df = pd.read_excel(input_file)

if not "Product URL" in input_df.columns:
    raise Exception("Excel must have a 'Product URL' column")

URL_LIST = input_df["Product URL"].tolist()


# ==========================================================
# Selenium Setup
# ==========================================================
driver = Driver(
    uc=True,
    incognito=True,
    headless=False,
    block_images=True,
)

stealth(
    driver=driver,
    languages=["en-US","en"],
    vendor="Google Inc.",
    platform="Win32",
    user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
    webgl_vendor="Intel Inc.",
    renderer="Intel Iris OpenGL",
    fix_hairline=True
    )
wait = WebDriverWait(driver, 10)


# ==========================================================
# Scraper Function
# ==========================================================
def scrape_product(BASEURL):
    print("Scraping =>", BASEURL)
    driver.get(BASEURL)
    time.sleep(3)

    # -------- VARIANT URLs --------
    try:
        buttons = wait.until(EC.presence_of_all_elements_located(
            (By.CSS_SELECTOR, '[data-comp="SwatchGroup "] button')))
    except:
        buttons = None

    url_collections = []

    if buttons:
        for button in buttons:
            html = button.get_attribute("outerHTML")
            variant_url = BASEURL
            if "selected" not in button.get_attribute("data-at"):

                soup_btn = BeautifulSoup(html, "html.parser")
                img_tag = soup_btn.select_one("img")

                if img_tag and img_tag.get("src"):
                    sku_digits = re.findall(r"\d+", img_tag.get("src"))
                    if sku_digits:
                        variant_url = f"{BASEURL}?skuId={sku_digits[0]}"

                else:
                    var_value = button.get_attribute("aria-label")
                    page = driver.page_source

                    sku_match = None
                    if var_value:
                        sku_match = re.findall(rf'displayName":"(\d+) {var_value}?","freeShippingMessage',page)
                        if sku_match == []:
                            sku_match = re.findall(rf'displayName":"(\d+) {var_value}?","freeShippingType',page)
                            if sku_match == []:
                                color = soup_btn.select_one('span').get_text(strip=True)
                                sku_match = re.findall(rf'","sku":"(\d+)","color":"{color}","image":"',page)

                    if sku_match:
                        sku_id = sku_match[0]
                        variant_url = f"{BASEURL}?skuId={sku_id}"

            url_collections.append(variant_url)
    else:
        url_collections.append(BASEURL)



    products = []

    # -------- SCRAPE EACH VARIANT --------
    for variant_url in url_collections:
        print(variant_url)
        driver.get(variant_url)
        time.sleep(5)

        html = driver.page_source
        soup = BeautifulSoup(html, "html.parser")

        meta_title = soup.select_one("title").get_text(strip=True) if soup.select_one("title") else ""
        print(meta_title)
        meta_desc = ""
        try:
            meta_desc = soup.select_one('meta[name="description"]').get("content", "")
        except:
            response = requests.get(variant_url,headers)
            meta_soup = BeautifulSoup(response.text,"html.parser").select_one('meta[name="description"]')
            if meta_soup:
                meta_desc = meta_soup.get("content", "")

        body_html = wait.until(EC.presence_of_element_located((By.XPATH, "//body"))).get_attribute("outerHTML")
        soup = BeautifulSoup(body_html, "html.parser")

        # BASIC DATA
        title = soup.select_one('[data-at="product_name"]').get_text(strip=True) if soup.select_one('[data-at="product_name"]') else ""
        sku = soup.select_one('[data-at="item_sku"]').get_text(strip=True).replace("Item ", "") if soup.select_one('[data-at="item_sku"]') else ""
        brand = soup.select_one('[data-at="brand_name"]').get_text(strip=True) if soup.select_one('[data-at="brand_name"]') else ""
        price = soup.select_one('b[class="css-0"]').get_text(strip=True) if soup.select_one('b[class="css-0"]') else ""

        # -------- VARIANTS --------
        var_dict = {}
        variant_nodes = soup.select('[data-at="sku_name_label"] span, [data-at="sku_size_label"]')

        if variant_nodes:
            v = 1
            for item in variant_nodes:
                txt = item.get_text(strip=True)

                if ":" in txt:
                    name, val = txt.split(":", 1)
                else:
                    if txt.startswith("Size"):
                        name, val = "Size", txt.replace("Size", "").strip()
                    elif txt.startswith("Color"):
                        name, val = "Color", txt.replace("Color", "").strip()
                    else:
                        continue

                var_dict[f"Variant Name {v}"] = name.strip()
                var_dict[f"Variant Value {v}"] = val.strip()
                v += 1

        # -------- CATEGORY --------
        cat_dict = {}
        cats = soup.select('[aria-label="Breadcrumb"] li a')

        if cats:
            for idx, c in enumerate(cats, 1):
                txt = c.get_text(strip=True)
                link = c.get("href")
                link = link if link.startswith("http") else "https://www.sephora.com" + link

                cat_dict[f"Category Name {idx}"] = txt
                cat_dict[f"Category Link {idx}"] = link

        # -------- IMAGES --------
        img_dict = {}
        imgs = soup.select('[data-at="product_images"] picture source')

        if imgs:
            for i, tag in enumerate(imgs, 1):
                found = re.findall(r'https?://[^ ?]+', tag.get("srcset"))
                if found:
                    img_dict[f"Image Name {i}"] = f"{sku}_{i}"
                    img_dict[f"Image Link {i}"] = found[0]

        # -------- HIGHLIGHTS --------
        block = re.search(r'"highlights":\s*\[([\s\S]*?)\],\s*"ingredientDesc"', html)
        highlights = ""
        if block:
            highlights = "\n".join(re.findall(r'"name":"(.*?)"', block.group(1)))

        # -------- DESCRIPTION --------
        description = ""
        desc_raw = re.findall(r'\,\"longDescription\"\:.*\,\"longDescription\"\:\"(.*)?\"\,\"lovesCount"', html, flags=re.DOTALL)

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
        how_to_use = how_to.get_text("\n", strip=True) if how_to else ""

        # -------- FINAL ITEM --------
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
# SCRAPE ALL URLs
# ==========================================================
all_items = []
for uidx, url in enumerate(URL_LIST,1):
    print(f"{uidx} out of {len(URL_LIST)}")
    all_items.extend(scrape_product(url))


# ==========================================================
# CLEAN + BUILD ORDERED EXCEL
# ==========================================================
def build_excel(rows, output_name="sephora_output.xlsx"):
    print("\n📌 Building dynamic ordered Excel...")

    # ----- FIXED HEADERS -----
    FIXED = [
        "Product URL", "SKU", "Product Title", "Brand",
        "Price", "Description", "Ingredient", "How to Use",
        "Highlights", "Meta Title", "Meta Description"
    ]

    variant_headers = []
    image_headers = []
    category_headers = []

    # ----- Detect dynamic headers -----
    for item in rows:
        for key in item.keys():
            if "Variant Name" in key or "Variant Value" in key:
                if key not in variant_headers:
                    variant_headers.append(key)

            if "Image Name" in key or "Image Link" in key:
                if key not in image_headers:
                    image_headers.append(key)

            if "Category Name" in key or "Category Link" in key:
                if key not in category_headers:
                    category_headers.append(key)

    # Sort naturally: 1,2,3...
    variant_headers = sorted(variant_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))
    image_headers = sorted(image_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))
    category_headers = sorted(category_headers, key=lambda x: int(re.findall(r'\d+', x)[0]))

    # ----- FINAL HEADER ORDER -----
    FINAL_HEADERS = FIXED + variant_headers + image_headers + category_headers

    df = pd.DataFrame(rows)
    df = df.reindex(columns=FINAL_HEADERS)

    df.to_excel(output_name, index=False)
    print("Excel saved as:", output_name)


# Build final Excel
build_excel(all_items,output_name=output_file)
driver.quit()
print("Scraping completed successfully!")