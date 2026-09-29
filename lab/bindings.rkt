#lang racket

;;; bindings.rkt —— 策略：具体键位表（唯一提键名的地方）
;;;
;;; 机制（keymap.rkt / dispatch.rkt）不知道任何具体键；所有「哪个键干什么」都在这里。
;;; 想改键 / 加键，只动本文件。
;;;
;;; 四张表：
;;;   global-keymap  全局，永远垫在键位栈底（C-q 退出 / C-o 切焦点）
;;;   nav-keymap     基础光标导航（方向键），被 editor / tree 继承
;;;   editor-keymap  编辑格：导航 ⊕ 输入 / 编辑 / 撤销 / 多光标 / 高亮
;;;   tree-keymap    文件树：导航 ⊕ 打开 / 新建 / 删除
;;;   prompt-keymap  提示态（模态）：输入 / 回车确认 / Esc 取消，其余全吞
;;;
;;; 注意文本兜底（keymap 的 default）：
;;;   · editor-keymap 的 default = editor/insert → 任何可打印字符都是「输入」
;;;   · tree-keymap 无 default → 除 n/m/d/回车外一律忽略
;;;   · prompt-keymap 的 default = prompt/insert → 任何可打印字符进提示缓冲

(provide global-keymap nav-keymap editor-keymap tree-keymap prompt-keymap)

(require "keymap.rkt")

;;; ---------- 全局 ----------

(define global-keymap
  (km 'global
      (list (list 'C-q 'app/quit)
            (list 'C-o 'focus/toggle))))

;;; ---------- 基础导航（editor / tree 共享） ----------

(define nav-keymap
  (km 'nav
      (list (list 'left  'editor/left  (list #f))
            (list 'right 'editor/right (list #f))
            (list 'up    'editor/up    (list #f))
            (list 'down  'editor/down  (list #f)))))

;;; ---------- 编辑格 ----------

(define editor-keymap
  (keymap-extend
   nav-keymap
   (km 'editor
       (list
        ;; 输入 / 编辑
        (list 'enter     'editor/insert (list "\n" #f))    ; 换行：独立一步（tag #f）
        (list 'tab       'editor/insert (list "    " #f))
        (list 'backspace 'editor/backspace)
        (list 'del       'editor/delete)
        (list 'home      'editor/home (list #f))
        (list 'end       'editor/end  (list #f))
        (list 'pageup    'editor/pageup)
        (list 'pagedown  'editor/pagedown)
        (list 'escape    'editor/collapse)
        ;; Shift+方向：扩选
        (list 'S-left  'editor/left  (list #t))
        (list 'S-right 'editor/right (list #t))
        (list 'S-up    'editor/up    (list #t))
        (list 'S-down  'editor/down  (list #t))
        ;; Ctrl 组合
        (list 'C-z 'editor/undo)
        (list 'C-y 'editor/redo)
        (list 'C-s 'file/save)        ; 写入当前文档
        (list 'C-w 'file/close)       ; 关闭当前文档（脏则先问是否写入）
        (list 'C-c 'editor/copy)
        (list 'C-v 'editor/paste)
        (list 'C-t 'editor/toggle-wrap)
        (list 'C-g 'editor/toggle-line-numbers)
        (list 'C-d 'editor/add-cursor-next)
        (list 'C-m 'editor/add-cursor-all)
        (list 'C-k 'editor/highlight (list 'kw))
        (list 'C-l 'editor/highlight (list #f))
        (list 'C-r 'editor/readonly (list #t))
        (list 'C-n 'editor/readonly (list #f))
        ;; Alt / Ctrl+Shift+方向：上下加光标
        (list 'M-down  'editor/add-cursor-line (list +1))
        (list 'M-up    'editor/add-cursor-line (list -1))
        (list 'CS-down 'editor/add-cursor-line (list +1))
        (list 'CS-up   'editor/add-cursor-line (list -1)))
       ;; 文本兜底：可打印字符 → 插入（文本并入 payload）
       (bind 'editor/insert))))

;;; ---------- 文件树 ----------

(define tree-keymap
  (keymap-extend
   nav-keymap
   (km 'tree
       (list (list 'enter 'tree/activate)
             (list #\n   'tree/new-file)
             (list #\m   'tree/new-dir)
             (list #\d   'tree/delete))
       #f            ; 无文本兜底：其它字符忽略
       #f)))

;;; ---------- 提示态（模态） ----------

(define prompt-keymap
  (km 'prompt
      (list (list 'enter     'prompt/confirm)
            (list 'escape    'prompt/cancel)
            (list 'backspace 'prompt/backspace)
            (list 'C-q       'app/quit))
      (bind 'prompt/insert)     ; 文本兜底：进缓冲
      #t))                      ; 模态：未绑定的键全吞（不落给编辑器）

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "key.rkt" "dispatch.rkt" "intent.rkt")

  ;; 编辑格：字符 → 插入；Ctrl 组合 → 对应命令
  (check-equal? (intent-tag (dispatch (list editor-keymap) (make-stroke #\a) 0)) 'editor/insert)
  (check-equal? (intent-payload (dispatch (list editor-keymap) (make-stroke #\a) 0)) '("a"))
  (check-equal? (intent-tag (dispatch (list editor-keymap) (make-stroke 'C-z) 0)) 'editor/undo)
  (check-equal? (intent-tag (dispatch (list editor-keymap) (make-stroke 'C-s) 0)) 'file/save)
  (check-equal? (intent-tag (dispatch (list editor-keymap) (make-stroke 'C-w) 0)) 'file/close)
  (check-equal? (intent-tag (dispatch (list editor-keymap) (make-stroke 'S-left) 0)) 'editor/left)
  (check-equal? (intent-payload (dispatch (list editor-keymap) (make-stroke 'S-left) 0)) (list #t))
  (check-equal? (intent-payload (dispatch (list editor-keymap) (make-stroke 'M-down) 0)) (list +1))

  ;; 换行 payload = ("\n" #f)：tag #f 表示不并入打字步
  (check-equal? (intent-payload (dispatch (list editor-keymap) (make-stroke 'enter) 0)) (list "\n" #f))

  ;; 树：n/m/d/回车；其它字符忽略
  (check-equal? (intent-tag (dispatch (list tree-keymap) (make-stroke #\n) 0)) 'tree/new-file)
  (check-equal? (intent-tag (dispatch (list tree-keymap) (make-stroke 'enter) 0)) 'tree/activate)
  (check-false (dispatch (list tree-keymap) (make-stroke #\x) 0))
  ;; 方向键从 nav 继承
  (check-equal? (intent-tag (dispatch (list tree-keymap) (make-stroke 'down) 0)) 'editor/down)

  ;; 提示态：模态吞掉未绑定键；C-q 仍可退出
  (check-equal? (intent-tag (dispatch (list prompt-keymap editor-keymap) (make-stroke 'enter) 0)) 'prompt/confirm)
  (check-equal? (intent-tag (dispatch (list prompt-keymap editor-keymap) (make-stroke #\y) 0)) 'prompt/insert)
  (check-false (dispatch (list prompt-keymap editor-keymap) (make-stroke 'up) 0))
  (check-equal? (intent-tag (dispatch (list prompt-keymap global-keymap) (make-stroke 'C-q) 0)) 'app/quit)

  (displayln "lab/bindings.rkt: all tests passed"))
