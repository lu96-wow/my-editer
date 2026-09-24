#lang racket

;;; events.rkt —— 后端无关的类型化输入事件（参考 racket/gui 事件模型）
;;;
;;; 事件是整程序级的原始输入（不是 窗口/缓冲 级）：
;;;   · 类型化 struct，按结构谓词分派
;;;   · 修饰键独立为布尔
;;;   · 键事件（物理键）与 文本事件（翻译后文本）分离，
;;;     解决「Ctrl+B 分屏 vs 输入 b」的歧义；IME/粘贴统一走 文本事件
;;;   · 坐标 0-based 屏幕坐标（后端在边界转换）

(provide
 (struct-out 修饰键)
 (struct-out 文本事件)
 (struct-out 键事件)
 (struct-out 鼠标按下事件)
 (struct-out 鼠标滚轮事件)
 (struct-out 尺寸变更事件)
 (struct-out 退出事件))

(struct 修饰键 (控制 Alt 平移 Meta) #:transparent)

;; 已解码文本（含 IME / 粘贴的多字符）
(struct 文本事件 (文本 修饰键) #:transparent)

;; 物理键：键 ∈ 字符（可打印键 + 修饰，如 控制+#\b）
;;               | symbol（'上 '下 '左 '右 '行首 '末尾 'pageup 'pagedown
;;                         '退格 '删除 'enter 'tab 'escape 'f1..'f12）
(struct 键事件 (键 修饰键) #:transparent)

;; 鼠标（x/y 0-based 屏幕坐标）
(struct 鼠标按下事件 (按键 x y 修饰键) #:transparent)
(struct 鼠标滚轮事件 (方向 x y 修饰键) #:transparent)

;; 尺寸（缓冲 区）
(struct 尺寸变更事件 (屏行列表 列数) #:transparent)

;; 生命周期
(struct 退出事件 () #:transparent)
