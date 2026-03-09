try {
  const request = {
    url: "https://gemini.google.com/generate_204",
    headers: {
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    },
    timeout: 5000
  };

  $httpClient.get(request, function(error, response, data) {
    if (error) {
      $done({ title: "✨ Gemini", content: "Timeout", backgroundColor: "#FF3B30", icon: "sparkles" });
      return;
    }

    const status = response.status || response.statusCode;

    if (status === 403) {
      $done({ title: "✨ Gemini", content: "Blocked", backgroundColor: "#FF3B30", icon: "sparkles" });
    } else if (status === 204 || status === 200) {
      $done({ title: "✨ Gemini", content: "Unlocked", backgroundColor: "#1A73E8", icon: "sparkles" });
    } else {
      $done({ title: "✨ Gemini", content: "Unknown (" + status + ")", backgroundColor: "#FF9F0A", icon: "sparkles" });
    }
  });
} catch(e) {
  $done({});
}
