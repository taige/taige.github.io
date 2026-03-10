async function request(method, params) {
  return new Promise((resolve) => {
    $httpClient[method.toLowerCase()](params, (error, response, data) => {
      resolve({ error, response, data });
    });
  });
}

async function main() {
  const { error, response, data } = await request("GET", "https://api.openai.com/compliance/cookie_requirements");

  if (error) {
    $done({ title: "🤖 ChatGPT", content: "Network Error", backgroundColor: "#FF3B30", icon: "waveform.path.ecg" });
    return;
  }

  if (data && data.includes("unsupported_country")) {
    $done({ title: "🤖 ChatGPT", content: "Blocked", backgroundColor: "#FF3B30", icon: "waveform.path.ecg" });
    return;
  }

  $done({ title: "🤖 ChatGPT", content: "Available", backgroundColor: "#10A37F", icon: "waveform.path.ecg" });
}

(async () => {
  main()
    .then((_) => {})
    .catch((error) => {
      $done({});
    });
})();
