#lang racket

;;; edit-rebuild/core/key.rkt —— 绑定键与输入事件（纯）
;;;
;;; 输入骨架只认识「绑定键」，不认识终端字节。终端事件 → 绑定键由后端负责
;;; （旧树在 core/command/binding.rkt，是唯一 require tui 的地方；这一层刻意不碰）。
;;;
;;; 绑定键分三类：
;;;   key-binding    命名键 / 字符键 + 修饰（如 (key 'p 'ctrl)）
;;;   mouse-binding  鼠标动作 + 按键 + 修饰
;;;   chan-binding   通道（text / paste / resize）
;;;
;;; 输入事件 = 绑定键 + 载荷（文本 / 尺寸 / 坐标）。

(require racket/list)

(provide
 (struct-out mods)
 (struct-out key-binding) (struct-out mouse-binding) (struct-out chan-binding)
 (struct-out input) (struct-out event)
 mod-order mods->symbols normalize-mods
 key mouse text-binding paste-binding resize-binding
 binding-eq?
 text-spec paste-spec resize-spec mouse-press-spec mouse-scroll-up-spec mouse-scroll-down-spec)

;;; ---------- 修饰键 ----------

(struct mods (ctrl? alt? shift?) #:transparent)

(define mod-order '(ctrl alt shift))

(define (mods->symbols m)
  (for/list ([s (in-list mod-order)]
             [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
             #:when on?)
    s))

;; 规范序：ctrl < alt < shift；去重、丢未知。
(define (normalize-mods ms)
  (sort (remove-duplicates (filter symbol? ms))
        < #:key (lambda (s) (or (index-of mod-order s) 99))))

;;; ---------- 绑定键 ----------

(struct key-binding (key mods) #:transparent)
;; key  : symbol（命名键如 'up 'tab 'enter）| char（可打印字符）
;; mods : (listof symbol) 规范序

(struct mouse-binding (action button mods) #:transparent)
;; action : 'press | 'release | 'move | 'scroll
;; button : 'left | 'middle | 'right | 'up | 'down
;; mods   : (listof symbol)

(struct chan-binding (chan) #:transparent)
;; chan : 'text | 'paste | 'resize

(define (key k . ms) (key-binding k (normalize-mods ms)))
(define (mouse action button . ms) (mouse-binding action button (normalize-mods ms)))
(define (text-binding) (chan-binding 'text))
(define (paste-binding) (chan-binding 'paste))
(define (resize-binding) (chan-binding 'resize))

(define (binding-eq? a b) (equal? a b))

;;; ---------- 输入事件 ----------

(struct input (binding text cols rows col row) #:transparent)
;; binding   : key-binding | mouse-binding | chan-binding | #f
;; text      : string | #f       文本 / 粘贴载荷
;; cols rows : integer | #f      resize 载荷
;; col row   : integer | #f      鼠标载荷（屏幕 0-based）

;;; ---------- 生命周期事件 ----------
;;;
;;; 除了输入，还有宿主发出的通知（before-render / focus-changed / after-nav /
;;; document-closed / log-appended / prompt-closed …）。它们是**事件**，不是按键，
;;; 但同样用「作用域 + 动作」声明式表达（见 route.rkt / dispatch.rkt 的 emit）。
(struct event (tag payload) #:transparent)
;; tag     : symbol
;; payload : any/c

;;; ---------- 载荷型 spec 标记 ----------
;;;
;;; 路由动作若是这些符号，引擎用「输入的载荷」换成具体命令（宿主提供 spec->action）。
;;; 与旧 dispatch.rkt 的 spec->cmd 同构，但换成数据标记而非过程。

(define text-spec 'text)
(define paste-spec 'paste)
(define resize-spec 'resize)
(define mouse-press-spec 'mouse-press)
(define mouse-scroll-up-spec 'mouse-scroll-up)
(define mouse-scroll-down-spec 'mouse-scroll-down)
