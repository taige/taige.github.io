async function request(method, params) {
  return new Promise((resolve) => {
    $httpClient[method.toLowerCase()](params, (error, response, data) => {
      resolve({ error, response, data });
    });
  });
}

async function main() {
  const { error, response } = await request("GET", {
    url: "https://gemini.google.com/generate_204",
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    },
  });

  if (error) {
    $done({ content: "Network Error", backgroundColor: "#FF9500" });
    return;
  }

  const status = response.status || response.statusCode;

  if (status === 403) {
    $done({ content: "Blocked", backgroundColor: "#FF9500" });
    return;
  }

  if (status === 204 || status === 200) {
    $done({ content: "Available", backgroundColor: "#1A73E8" });
    return;
  }

  $done({ content: "Unknown (" + status + ")", backgroundColor: "#FF9500" });
}

(async () => {
  main()
    .then((_) => {})
    .catch((error) => {
      $done({});
    });
})();
