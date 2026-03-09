try {
  const request = {
    url: "https://claude.ai/login",
    headers: {
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    },
    timeout: 5000
  };

  $httpClient.get(request, function(error, response, data) {
    if (error) {
      $done({ title: "🧠 Claude", content: "Timeout", backgroundColor: "#FF3B30", icon: "brain.head.profile" });
      return;
    }

    const status = response.status || response.statusCode;

    if (status === 403 || status === 401) {
      $done({ title: "🧠 Claude", content: "Blocked", backgroundColor: "#FF3B30", icon: "brain.head.profile" });
    } else if (status === 200) {
      // 检查响应体是否包含封锁提示
      if (data && (data.includes("unavailable") || data.includes("not available in your country"))) {
        $done({ title: "🧠 Claude", content: "Blocked", backgroundColor: "#FF3B30", icon: "brain.head.profile" });
      } else {
        $done({ title: "🧠 Claude", content: "Unlocked", backgroundColor: "#D97757", icon: "brain.head.profile" });
      }
    } else {
      $done({ title: "🧠 Claude", content: "Unknown (" + status + ")", backgroundColor: "#FF9F0A", icon: "brain.head.profile" });
    }
  });
} catch(e) {
  $done({});
}
