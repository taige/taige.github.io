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
    "https://api.openai.com/compliance/cookie_requirements"
  );

  if (error) {
    $done({ content: "Network Error", backgroundColor: "#FF9500" });
    return;
  }

  if (data && data.toLowerCase().includes("unsupported_country")) {
    $done({ content: "Blocked", backgroundColor: "#FF9500" });
    return;
  }

  $done({ content: "Available", backgroundColor: "#10A37F" });
}

(async () => {
  main()
    .then((_) => {})
    .catch((error) => {
      $done({});
    });
})();
