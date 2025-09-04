(() => {
    console.log("🚀 脚本启动");

    let confirmCount = 0; // 确定按钮点击次数
    let startCount = 0;   // 免费开始使用吧点击次数
    let stopFlag = false; // 循环停止标志

    function forceClickConfirm() {
        const confirmBtn = Array.from(document.querySelectorAll('button')).find(b => b.innerText.includes('确定'));
        if (confirmBtn) {
            confirmBtn.click();
            confirmCount++;
            console.log(`✅ 点击【确定】按钮成功，累计次数: ${confirmCount}`);
        }
    }

    function forceClickStart() {
        const spans = Array.from(document.querySelectorAll('span')).filter(s => s.innerText.includes('免费开始使用吧'));
        if (spans.length === 0) {
            console.log("❌ 页面中没有【免费开始使用吧】按钮，停止循环");
            stopFlag = true;
            console.log(`📊 最终点击统计 → 确定按钮: ${confirmCount} 次, 免费开始使用吧: ${startCount} 次`);
            return false;
        }

        const btn = spans.length >= 2 ? spans[1].closest('button') || spans[1] : spans[0].closest('button') || spans[0];
        if (btn) {
            btn.click();
            startCount++;
            console.log(`✅ 点击【免费开始使用吧】按钮成功，累计次数: ${startCount}`);
        }
    }

    function loop() {
        if (stopFlag) return;
        forceClickConfirm();   // 先点击确定
        setTimeout(() => {
            forceClickStart(); // 延迟点击免费开始使用吧
            if (!stopFlag) {
                setTimeout(loop, 5000); // 每5秒重复一次
            }
        }, 5000);
    }

    loop();
})();
