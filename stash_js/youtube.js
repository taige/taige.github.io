async function request(method, params) {
  return new Promise((resolve) => {
    $httpClient[method.toLowerCase()](params, (error, response, data) => {
      resolve({ error, response, data });
    });
  });
}

async function main() {
  const { error, response, data } = await request(
    "GET",
    "https://m.youtube.com/premium"
  );

  if (error) {
    $done({ content: "Network Error", backgroundColor: "#FF9500" });
    return;
  }

  const body = (data || "").toLowerCase();

  if (body.includes("youtube premium is not available in your country")) {
    $done({ content: "Not Available", backgroundColor: "#FF9500" });
    return;
  }

  if (body.includes("ad-free") || body.includes("adfree")) {
    const match = data.match(/"GL"\s*:\s*"([A-Z]{2})"/i);
    const country = match ? " (" + match[1] + ")" : "";
    $done({ content: "Available" + country, backgroundColor: "#FF0000" });
    return;
  }

  $done({ content: "Unknown Error", backgroundColor: "#FF9500" });
}

(async () => {
  main()
    .then((_) => {})
    .catch((error) => {
      $done({});
    });
})();
