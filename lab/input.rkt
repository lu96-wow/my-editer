#lang racket

;;; ============================================================================
;;; input.rkt —— 抽象输入（后端无关）
;;; ============================================================================
;;;
;;; 这一层是「后端」和「文档」之间唯一的接口。任何后端（终端 / GUI / headless
;;; 测试）都只做一件事：把它自己的原始事件翻译成这里的四种值之一。
;;; 文档和壳只认这四种值，因此永远不依赖任何具体后端。
;;;
;;;   key      按键：名字（char 或 symbol）+ 四个修饰位
;;;   text     一段文本（粘贴 / 输入法 / 多字符输入）
;;;   pointer  鼠标：动作 + 按键 + 屏幕坐标（0-based）+ 修饰位
;;;   resize   窗口尺寸变化
;;;
;;; 约定：
;;;   · 名字用 char 表示普通字符（#\a、#\n…），用 symbol 表示命名键（'enter、
;;;     'escape、'up…）；修饰位用四个布尔，后端直接填。
;;;   · **没有「键编码」函数**（不存在把 Ctrl+A 拼成某个 token 的步骤）——
;;;     文档要匹配的就是 struct 字段本身。
;;;   · 都是不可变纯值，可比较、可打印、可单测；后端 → 文档 → 壳之间只传值。

(provide (struct-out key)
         (struct-out text)
         (struct-out pointer)
         (struct-out resize)
         key-of)

;;; ---------- 类型 ----------

(struct key (name ctrl? alt? shift? meta?) #:transparent)
;; name  : (or/c char? symbol?)
;; ctrl? / alt? / shift? / meta? : bool
;; 约定：带 Ctrl 的字母一律**小写**（终端给的是大写），用 key-of 构造。

;; 规范构造：Ctrl+字母 → 小写（"Ctrl-Q" 统一成 #\q）。
(define (key-of name ctrl? alt? shift? meta?)
  (key (if (and ctrl? (char? name)) (char-downcase name) name)
       ctrl? alt? shift? meta?))

(struct text (s) #:transparent)
;; s : string（粘贴 / 输入法 / 一次多个字符）

(struct pointer (action button row col ctrl? alt? shift? meta?) #:transparent)
;; action : 'press | 'release | 'move | 'scroll
;; button : 'left | 'middle | 'right（press/release）
;;          'up | 'down（scroll）
;;          #f（move）
;; row / col : 屏幕坐标（0-based，整屏左上角为原点）
;; 说明：终端用「按钮事件跟踪」，只有按住键拖动时才会上报 move —— 所以 move
;;       就等价于「拖拽」。

(struct resize (rows cols) #:transparent)

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define k (key #\o #t #f #f #f))
  (check-true (key? k))
  (check-equal? (key-name k) #\o)
  (check-true (key-ctrl? k))
  (check-false (key-alt? k))

  (check-equal? (text-s (text "你好")) "你好")
  (check-equal? (resize-rows (resize 20 80)) 20)
  ;; 规范构造：Ctrl+字母归一为小写
  (check-equal? (key-of #\Q #t #f #f #f) (key #\q #t #f #f #f))
  (check-equal? (key-of #\A #f #f #f #f) (key #\A #f #f #f #f))
  (check-true (pointer? (pointer 'press 'left 3 7 #f #f #f #f)))
  (check-equal? (pointer-row (pointer 'move #f 3 7 #f #f #f #f)) 3)

  ;; 纯值可比较（后端与文档之间只传值）
  (check-equal? (key 'enter #f #f #f #f) (key 'enter #f #f #f #f))

  (displayln "lab-rebuild/input.rkt: all tests passed"))
