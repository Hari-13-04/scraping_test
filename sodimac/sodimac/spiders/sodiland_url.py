import scrapy
import re
import warnings
from datetime import datetime
import os
import time
import pandas as pd
import boto3
from io import StringIO

warnings.filterwarnings('ignore')

# Use IAM role (NO hardcoded keys)
s3_client = boto3.client("s3")
bucket = os.getenv("S3_BUCKET", "aceinternationalcrawl")


def file_name_checker(name):
    for char in ['@','$','%','&','\\','/',':','*','?','"',"'",'<','>','|','~','`','#','^','+','=','{','}','[',']',';','!']:
        name = name.replace(char, "__")
    return name


class SodiSpider(scrapy.Spider):
    name = "sodiland_url"

    def __init__(self, input_file=None, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.input_file = input_file
        self.items = []

    def start_requests(self):

        if not self.input_file:
            raise ValueError("Input file not provided!")

        df = pd.read_excel(self.input_file).fillna("")

        for _, row in df.iterrows():
            url = row.get("url")
            if url:
                yield scrapy.Request(url, callback=self.parse)

    def parse(self, response):

        try:
            item = {}
            item["Product Url"] = response.url

            title = response.xpath(
                '//h1[contains(@class,"product-title")]/text()'
            ).get(default="").strip()

            item["Title"] = title

            sku_match = re.findall(r'"sku"\:\s*"([^"]+)"', response.text)
            sku = sku_match[0] if sku_match else ""

            item["Sku"] = sku

            upload_name = sku if sku else title
            target_file = f"data/Sodimac/{file_name_checker(upload_name)}.html"

            s3_bucket_store(target_file, response.text)

            item["Image"] = "".join(
                re.findall(r'"image"\:\s*"([^"]+)"', response.text)
            )

            item["Brand"] = (
                re.findall(r'"brandName":"(.*?)"', response.text)[0]
                if re.findall(r'"brandName":"(.*?)"', response.text)
                else ""
            )

            item["Taxonamy"] = " | ".join([
                tax.strip()
                for tax in response.xpath(
                    '//div[contains(@class,"bread-crumb")]//span[@itemprop="name"]/text()'
                ).getall()[:-1]
                if tax.strip()
            ])

            item["End Category"] = item["Taxonamy"].split(" | ")[-1] if item["Taxonamy"] else ""

            self.items.append(item)

            yield item

        except Exception as e:
            print("Error:", e)