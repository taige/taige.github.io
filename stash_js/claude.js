async function request(method, params) {
  return new Promise((resolve) => {
    $httpClient[method.toLowerCase()](params, (error, response, data) => {
      resolve({ error, response, data });
    });
  });
}

async function main() {
  const { error, response, data } = await request("GET", {
    url: "https://api.anthropic.com/v1/models",
    headers: {
      "x-api-key": "test",
      "anthropic-version": "2023-06-01",
    },
  });

  if (error) {
    $done({ content: "Network Error", backgroundColor: "" });
    return;
  }

  const status = response.status || response.statusCode;

  if (status === 403) {
    $done({ content: "Blocked", backgroundColor: "" });
    return;
  }

  if (status === 401) {
    $done({ content: "Available", backgroundColor: "#D97757" });
    return;
  }

  $done({ content: "Unknown (" + status + ")", backgroundColor: "" });
}

(async () => {
  main()
    .then((_) => {})
    .catch((error) => {
      $done({});
    });
})();
