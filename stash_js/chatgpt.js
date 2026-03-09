try {
  const request = {
    url: "https://chatgpt.com/cdn-cgi/trace",
    headers: {
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    },
    timeout: 5000
  };

  $httpClient.get(request, function(error, response, data) {
    if (error) {
      $done({ title: "🤖 ChatGPT", content: "Timeout", backgroundColor: "#FF3B30", icon: "waveform.path.ecg" });
      return;
    }

    if (data) {
      const match = data.match(/loc=([A-Z]{2})/);
      if (match && match[1]) {
        const loc = match[1];
        if (["CN", "HK", "RU", "KP", "IR", "SY", "CU"].includes(loc)) {
          $done({ title: "🤖 ChatGPT", content: "Blocked (" + loc + ")", backgroundColor: "#FF3B30", icon: "waveform.path.ecg" });
        } else {
          $done({ title: "🤖 ChatGPT", content: "Unlocked (" + loc + ")", backgroundColor: "#10A37F", icon: "waveform.path.ecg" });
        }
        return;
      }
    }

    $done({ title: "🤖 ChatGPT", content: "Error", backgroundColor: "#FF9F0A", icon: "waveform.path.ecg" });
  });
} catch(e) {
  $done({});
}
