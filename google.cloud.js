(function(){
  console.log("🚀 启动循环强制点击脚本（带日志统计）");

  let stopFlag = false;
  let confirmCount = 0; // 记录【确定】按钮点击次数
  let startCount = 0;   // 记录【免费开始使用吧】按钮点击次数

  // ===== 模拟完整用户点击事件 =====
  function simulateClick(el){
    if(!el) return;
    ['pointerover','mouseover','pointerdown','mousedown','mouseup','click']
      .forEach(type => el.dispatchEvent(new MouseEvent(type, {bubbles:true,cancelable:true,view:window})));
  }

  // ===== 强制点击【确定】按钮 (shadow DOM) =====
  function forceClickConfirm(){
    const allHosts = document.querySelectorAll('[jsshadow]');
    for (const host of allHosts) {
      const shadow = host.shadowRoot || host;
      const span = [...shadow.querySelectorAll('button span')]
        .find(el => el.textContent.trim() === "确定");
      if(span){
        const btn = span.closest('button') || span;
        simulateClick(btn);
        confirmCount++;
        console.log(`✅ 点击【确定】按钮成功，累计次数: ${confirmCount}`);
        return true;
      }
    }
    return false;
  }

  // ===== 强制点击第二个【免费开始使用吧】按钮 =====
  function forceClickStart(){
    const spans = [...document.querySelectorAll('span.ng-star-inserted')]
      .filter(span => span.textContent.trim() === "免费开始使用吧");
    
    if(spans.length === 0){
      console.log("❌ 页面中没有【免费开始使用吧】按钮，停止循环");
      stopFlag = true;
      console.log(`📊 最终点击统计 → 确定按钮: ${confirmCount} 次, 免费开始使用吧: ${startCount} 次`);
      return false;
    }

    let btn;
    if(spans.length >= 2){
      btn = spans[1].closest('button') || spans[1];
    } else {
      btn = spans[0].closest('button') || spans[0];
    }

    simulateClick(btn);
    startCount++;
    console.log(`✅ 点击【免费开始使用吧】按钮成功，累计次数: ${startCount}`);
    return true;
  }

  // ===== 循环执行 =====
  const intervalId = setInterval(() => {
    if(stopFlag){
      clearInterval(intervalId);
      console.log("🛑 循环已停止");
      console.log(`📊 最终点击统计 → 确定按钮: ${confirmCount} 次, 免费开始使用吧: ${startCount} 次`);
      return;
    }
    forceClickConfirm();
    setTimeout(forceClickStart, 5000); // 5秒后点击开始按钮
  }, 10000); // 每10秒循环一次
})();
