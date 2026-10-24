#!/bin/zsh
# 双击运行：把剪贴板里歌词的中文段标（【主歌1】等）换成英文方括号标记，
# 然后写回剪贴板。回到灵感助手直接粘贴就行。

cd "$(dirname "$0")" || exit 1

echo "正在转换剪贴板里的歌词……"
echo ""

/usr/bin/python3 fix_section_tags.py
status=$?

echo ""
if [ "$status" -eq 0 ]; then
  echo "转好了，已经放回剪贴板 —— 回灵感助手粘贴就行。"
  osascript -e 'display notification "结构标记已转成英文，回灵感助手粘贴就行。" with title "歌词段标转换"' 2>/dev/null
else
  echo "转换失败，看看上面的提示。"
  osascript -e 'display notification "转换失败，看看终端里的提示。" with title "歌词段标转换"' 2>/dev/null
fi

echo ""
echo "（窗口可以直接关掉）"
