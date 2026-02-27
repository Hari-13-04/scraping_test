import argparse,os
import requests
import json
import pandas as pd
from itertools import chain
from time  import sleep
from bs4 import BeautifulSoup
from parsel import Selector


headers = {
  'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  'accept-language': 'en-GB,en-US;q=0.9,en;q=0.8',
  'priority': 'u=0, i',
  'sec-ch-ua': '"Not;A=Brand";v="99", "Google Chrome";v="139", "Chromium";v="139"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"Windows"',
  'sec-fetch-dest': 'document',
  'sec-fetch-mode': 'navigate',
  'sec-fetch-site': 'none',
  'sec-fetch-user': '?1',
  'upgrade-insecure-requests': '1',
  'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36',
  'Cookie': 'Store=70; CART_SESSION=33a34e770a354f778cc4c8a8d6a4a8bf93ff954c5ecd465daa910199b7bf599c; _gcl_au=1.1.39343214.1756988263; __kla_id=eyJjaWQiOiJNR0l5WWpSbU5XTXRPREExWkMwME56ZzBMV0kyTXpVdE5XRXdNV1V5WkRoaVpUQTAifQ==; _ga=GA1.1.1833679925.1756988264; _fbp=fb.1.1756988264420.350046913984731010; _bti=%7B%22app_id%22%3A%22mccoys-building-supply%22%2C%22bsin%22%3A%22B5oCP557w%2FAJSr71SYWPj1gX5SMxRJSgG7zyYnyE3Mo9RnURE7Sefc56OVYbblSEDUaAWbH%2BlAqOJHv%2Fb8vDZg%3D%3D%22%2C%22is_identified%22%3Afalse%7D; _ga_DJ2VK509SK=GS2.1.s1756988263$o1$g0$t1756988273$j50$l0$h0; OptanonAlertBoxClosed=2025-09-04T12:19:11.873Z; __cf_bm=XJDyqAFhLPQOJaC3bETky_wjvKgbBw3UWY6n0w_5S5Q-1757048408-1.0.1.1-oAIZ69zdnJNYxWNH5V9Ci4A812oHmTm2A6xSvJwWBjryT6ur9NxZZtMRwmqr8f1I.FMQwX0vRu8QnjBPMlsyvhrkiux2n9vZvOXr9rjozVc; OptanonConsent=isGpcEnabled=0&datestamp=Fri+Sep+05+2025+10%3A30%3A42+GMT%2B0530+(India+Standard+Time)&version=202407.2.0&browserGpcFlag=0&isIABGlobal=false&hosts=&consentId=0e88c970-9d6e-4902-849e-c9d0716a882a&interactionCount=2&isAnonUser=1&landingPath=NotLandingPage&groups=C0001%3A1%2CC0003%3A1%2CC0002%3A0%2CBG15%3A0%2CC0004%3A0&AwaitingReconsent=false&intType=3&geolocation=IN%3BTN'
}
parser = argparse.ArgumentParser(description="Sephora Product Scraper (Playwright)")
parser.add_argument("--input", required=True, help="Input Excel file path")
parser.add_argument("--output", required=False, help="Output Excel file path (optional)")
args = parser.parse_args()

input_file = args.input
if args.output:
    output_name = args.output
else:
    base = os.path.splitext(os.path.basename(input_file))[0]
    output_name = base + "_output.xlsx"


def response(url: str):
    return requests.get(url,headers=headers,timeout=5)

def complain_filter(context):
    if "Restricted for Sale" not in context:return context


def link_name_extraction(css_selector:str,soup:BeautifulSoup,data:dict,head_name:str):
    links = soup.select(css_selector) if soup.select(css_selector) else []
    if links != []:
        for i, a in enumerate(links, start=1):
            name = a.get_text(strip=True)
            href = a.get("href")
            src = a.get("src")
            if name and href:
                data[f"{head_name} Name {i}"] = name
                data[f"{head_name} Link {i}"] = href if href.startswith("http") else "https://www.mccoys.com"+href
            elif src:
                sku = data.get("SKU")
                mpn = data.get('Manufacturer Part number')
                title = data.get('Product Title')
                naming = sku or mpn or title
                name = f'{naming}_{i}'
                data[f"{head_name} Name {i}"] = name
                data[f"{head_name} Link {i}"] = src

def stripper(striplist:str):
    return striplist.strip()


def extract_data(url, idx, selectors):
    try:
        print(f"Processing the url: {url} and row number: {idx}")
        response_ = response(url)
        if response_.status_code != 200:
            return {"Product URL": url, "Error": f"HTTP {response_.status_code}"}

        # Parsers
        soup = BeautifulSoup(response_.text, "html.parser")
        sel = Selector(text=response_.text)

        data = {}

        # --- Generic field extractor ---
        def get_value(key, selector, multiple=False):
            """
            Extract value using XPath or CSS depending on key name.
            XPATH_KEYS -> use XPath
            Others     -> use CSS
            Always returns list if multiple=True, else string or None.
            """
            XPATH_KEYS = {"compliance"}
            if not selector or key not in selector:
                return None

            sel_str = selector[key]
            if key in XPATH_KEYS:  # use XPath
                if multiple:
                    try:
                        return [x.strip() for x in sel.xpath(sel_str).getall() if x.strip()]
                    except:
                        return []
                try:
                    return sel.xpath(sel_str).get(default="").strip()
                except:
                    return None
            else:  # use CSS
                if multiple:
                    try:
                        return [x.strip() for x in sel.css(sel_str).getall() if x.strip()]
                    except:
                        return []
                try:
                    return sel.css(sel_str).get(default="").strip()
                except:
                    return None
        # --- Fixed fields from JSON ---
        data["Product Title"] = sel.css(selectors["Title"]).get(default="").strip()
        data["Meta Title"] = sel.css(selectors["Meta_Title"]).get(default="").strip()
        meta_desc_tag = soup.select_one(selectors.get("Meta_Description"))
        data["Meta Description"] = meta_desc_tag.get("content") if meta_desc_tag else None

        meta_kw_tag = soup.select_one(selectors.get("Meta_keyword"))
        data["Meta Keyword"] = meta_kw_tag.get("content") if meta_kw_tag else None

        data["SKU"] = sel.xpath(selectors["SKU"]).get(default="").strip()
        data["Brand"] = sel.css(selectors["Brand"]).get(default="").strip()
        data["Variation Name"] = sel.css(selectors["variation_name"]).get(default="").strip()
        if data["Variation Name"]:
            data["Variation Name"] = data["Variation Name"].replace(":","")
        variant_values = soup.select(selectors.get("variation_value"))
        if variant_values:
            for var_value in variant_values:
                if not var_value.select_one("button"):
                    data["Variation Value"]=var_value.text.replace(data["Variation Name"]+":","").strip()
        description = get_value("Product_Description", selectors, multiple=True)

        data["Description"] = "\n".join(map(stripper,description)) if description !=[] else ""

        price_texts = get_value("Price", selectors, multiple=True)
        data["Product Price"] = " ".join(map(stripper,price_texts)) if price_texts != [] else None

        categories = get_value("Category", selectors, multiple=True)
        data["Taxonomy"] = " | ".join(map(stripper,categories)) if categories != [] else ""
        data["End Category"] = categories[-1].strip() if categories !=[] else None


        specvalue = soup.select(selectors['spec_value'])
        spechead = soup.select(selectors['spec_header'])
        if spechead != [] and specvalue != []:
            if len(spechead) == len(specvalue):
                attr_counter = 1
                for head,value in zip(spechead,specvalue):
                    data[f"Attribute Name {attr_counter}"] = head.get_text(strip=True)
                    data[f"Attribute Value {attr_counter}"] = value.get_text(strip=True)
                    attr_counter += 1

        # link_name_extraction(selectors.get("PDF"),soup=soup,data=data,head_name="PDF")
        link_name_extraction(selectors.get("Image"),soup=soup,data=data,head_name="Image")
        link_name_extraction(selectors.get("Category_links"),soup=soup,data=data,head_name="Category")
        try:
            feature_list = sel.css(selectors["feature"]).getall()
            if feature_list:
                for i, f in enumerate(feature_list, start=1):
                    text = f.strip()
                    if text:
                        data[f"Feature {i}"] = text
        except:
            pass

        data['Product URL']=url
        print("Product Data:",data)
        return data

    except Exception as e:
        return {"Product URL": url, "Error": str(e)}

def uniq_keep_order(seq):
    seen = set()
    res = []
    for x in seq:
        k = str(x).strip().lower()
        if k and k not in seen:
            seen.add(k)
            res.append(str(x).strip())
    return res


def df_excel(input_file:str,results:list) -> None:
    out_df = pd.json_normalize(results)
    fixed_headers = [
        "Product URL",
        "Product Title", "SKU","Variation Name","Variation Value", "Description", "Product Price","Brand",
        "Taxonomy", "End Category",
        "Meta Title", "Meta Description","Meta Keyword"
    ]

    # Collect dynamic headers from the DataFrame
    attribute_headers = [col for col in out_df.columns if col.startswith("Attribute")]
    attachment_headers = [col for col in out_df.columns if col.startswith("PDF")]
    image_headers = [col for col in out_df.columns if col.startswith("Image")]
    category_headers = [col for col in out_df.columns if col.startswith("Category")]
    video_headers = [col for col in out_df.columns if col.startswith("Video")]
    feature_headers = [col for col in out_df.columns if col.startswith("Feature")]

    final_headers = fixed_headers + feature_headers+ attribute_headers  + image_headers + attachment_headers + video_headers+category_headers
    out_df = out_df.reindex(columns=final_headers)

    category_name_headers = [col for col in out_df.columns if col.startswith("Category Name")]
    attribute_name_headers = [col for col in out_df.columns if col.startswith("Attribute Name")]

    another_df = out_df.copy()
    another_df[category_name_headers]  = another_df[category_name_headers].applymap(lambda v: v.strip() if isinstance(v, str) else v)
    another_df[attribute_name_headers] = another_df[attribute_name_headers].applymap(lambda v: v.strip() if isinstance(v, str) else v)

    another_df["__attrs__"] = another_df[attribute_name_headers].apply(
        lambda r: [x for x in r if pd.notna(x) and str(x).strip() != ""], axis=1
    )

    grp = (
        another_df.groupby(category_name_headers, dropna=False)["__attrs__"]
            .agg(lambda lists: uniq_keep_order(chain.from_iterable(lists)))
            .reset_index()
    )

    max_attrs = grp["__attrs__"].map(len).max() if not grp.empty else 0
    for i in range(1, max_attrs + 1):
        grp[f"Attribute {i}"] = grp["__attrs__"].map(lambda L: L[i-1] if len(L) >= i else pd.NA)
    grp = grp.drop(columns="__attrs__")
    final_cols = category_name_headers + [f"Attribute {i}" for i in range(1, max_attrs + 1)]
    unique_df = grp[final_cols]

    with pd.ExcelWriter(input_file,engine="openpyxl") as writer:
        out_df.to_excel(writer,sheet_name="Product Data",index=False)
        unique_df.to_excel(writer,sheet_name="Unique Attribute",index=False)



def main():
    # Load selectors JSON
    with open("xpath_json.json", "r", encoding="utf-8") as f:
        selectors = json.load(f)

    # Read input Excel
    df = pd.read_excel(input_file,dtype=str)

    results = []
    for idx, url in enumerate(df["Product URL"].dropna(), start=1):
        results.append(extract_data(url, idx, selectors))
    try:
        df_excel(output_name,results)
    except:
        print("No Data and excel cannot write")

    print("✅ Scraping complete. Data saved to output.xlsx")


if __name__ == "__main__":
    main()
