#lang racket

;;; 18 —— 命令层 demo：键序列表 + 组合 + racket-tui 输入
;;;
;;;   racket temp/18-command.rkt          # headless：喂合成事件，看编辑结果
;;;   racket temp/18-command.rkt tui      # 交互
;;;
;;; 键位：
;;;   ←/→/↑/↓ Home End     光标
;;;   Enter / Backspace     编辑
;;;   C-z / C-y             撤销 / 重做
;;;   C-x C-s               save（多键序列）
;;;   C-x C-c               退出
;;;   C-p ← / C-p →         前缀 + 方向
;;;   C-t                   运行时并入的新表（演示动态加表）
;;;   其它可打印字符         插入文本（键表未命中 → 文本通道）

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"        ; require 即装样式
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt")

;;; ════════════════════════ 应用状态 ════════════════════════

(define W (box 80))
(define H (box 24))
(define running? (box #t))
(define message (box ""))
(define save-count (box 0))
(define cache #f)

(define doc-b (make-buffer "(define (f x)\n  ;; doc\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define doc-v (buffer-add-view! doc-b #:line-numbers? #t))
(define sess  (make-edit-session doc-b))

(define (note! s) (set-box! message s))
(define (panels) (list (make-panel doc-v (rect 0 0 (unbox W) (sub1 (unbox H))) borders-all)))

;;; ════════════════════════ 命令表 ════════════════════════

(define (insert! text) (session-edit! sess doc-v (op-type text)))

(define edit-keys
  (keys
   [(key 'left)      (λ () (session-left! sess doc-v))]
   [(key 'right)     (λ () (session-right! sess doc-v))]
   [(key 'up)        (λ () (session-up! sess doc-v))]
   [(key 'down)      (λ () (session-down! sess doc-v))]
   [(key 'home)      (λ () (session-home! sess doc-v))]
   [(key 'end)       (λ () (session-end! sess doc-v))]
   [(key 'enter)     (λ () (insert! "\n"))]
   [(key 'backspace) (λ () (session-edit! sess doc-v (op-backspace)))]
   [(key 'delete)    (λ () (session-edit! sess doc-v (op-delete)))]
   [(key 'z 'ctrl)   (λ () (session-undo! sess) (note! "undo"))]
   [(key 'y 'ctrl)   (λ () (session-redo! sess) (note! "redo"))]))

(define global-keys
  (keys
   [(key 'x 'ctrl) (key 's 'ctrl)
    (λ () (set-box! save-count (add1 (unbox save-count)))
         (note! (format "saved via C-x C-s #~a" (unbox save-count))))]
   [(key 'x 'ctrl) (key 'c 'ctrl) (λ () (set-box! running? #f))]
   [(key 'p 'ctrl) (key 'left)    (λ () (note! "focus ← (C-p ←)"))]
   [(key 'p 'ctrl) (key 'right)   (λ () (note! "focus → (C-p →)"))]
   [(key 's 'ctrl)
    (λ () (set-box! save-count (add1 (unbox save-count)))
         (note! (format "saved via C-s #~a" (unbox save-count))))]))

;; 用户表：故意和 global-keys 的 C-s 绑同一条序列 —— 合并会直接报错
;; （新语义：冲突不覆盖，直接 error）。
(define conflicting-user-keys
  (keys [(key 's 'ctrl) (λ () (note! "never: 这张表不会被接受"))]))

;; 操作对象：可变的表列表。edit + global 合成活动表。
(define active-keys (make-keytable edit-keys global-keys))
(define reader (make-key-reader active-keys))

;;; ════════════════════════ 事件处理 ════════════════════════

;; 喂一个事件：命令层只返回 proc，这里执行；未命中且是可打印字符 → 文本通道。
;; 返回状态（headless 检查用）。
(define (handle-event! ev)
  (define-values (status proc) (key-reader-feed! reader ev))
  (case status
    [(command) (proc)]
    [(unbound)
     (define k (and (key-event? ev) (key-event-key ev)))
     (define m (and (key-event? ev) (key-event-mods ev)))
     (cond [(and (char? k) m (not (mods-ctrl? m)) (not (mods-alt? m)))
            (insert! (string k))]
           [else (note! (format "unbound: ~a" (if (key-event? ev) (key-event-key ev) ev)))])]
    [else (void)])
  status)

(define (press! k #:ctrl [c #f] #:alt [a #f])
  (handle-event! (key-event k (mods c a #f))))

;;; ════════════════════════ headless 自检 ════════════════════════

(define (run-check!)
  (printf "初始：\n~a\n" (buffer-string doc-b))
  (press! #\H) (press! #\i) (press! #\!)
  (check "插入 Hi!" (string-prefix? (buffer-string doc-b) "Hi!"))
  (press! 'x #:ctrl #t) (press! 's #:ctrl #t)
  (check "C-x C-s" (equal? (unbox message) "saved via C-x C-s #1"))
  ;; 冲突合并 → 报错，活动表不变（原子）
  (check "冲突表被拒绝"
         (with-handlers ([exn:fail? (λ (_) #t)])
           (keytable-merge! active-keys conflicting-user-keys)
           #f))
  (press! 's #:ctrl #t)
  (check "C-s 仍是 global" (equal? (unbox message) "saved via C-s #2"))
  ;; 运行时并入一张不冲突的新表，立即可用（读键器持有同一个 keytable）
  (keytable-merge! active-keys (keys [(key 't 'ctrl) (λ () (note! "dynamic C-t"))]))
  (press! 't #:ctrl #t)
  (check "运行时新表生效" (equal? (unbox message) "dynamic C-t"))
  (press! 'p #:ctrl #t)
  (check "C-p 进入前缀" (equal? (key-reader-pending-string reader) "C-p"))
  (press! 'left)
  (check "C-p ← 生效" (equal? (unbox message) "focus ← (C-p ←)"))
  (press! 'right) (press! 'right) (press! 'right)
  (press! 'backspace)
  (check "方向键 + Backspace" (string-prefix? (buffer-string doc-b) "Hi"))
  (press! 'z #:ctrl #t)
  (check "C-z 撤销" (string-prefix? (buffer-string doc-b) "Hi!"))
  (printf "\n结束：\n~a\n" (buffer-string doc-b))
  (displayln "command demo: 全部 OK"))

(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

;;; ════════════════════════ racket-tui 交互 ════════════════════════

(define (status-line)
  (define pend (key-reader-pending-string reader))
  (define s (string-append (if (string=? pend "") "" (format "[~a] " pend))
                           (unbox message)))
  (define w (unbox W))
  (cond [(> (string-length s) w) (substring s 0 w)]
        [else s]))

(define (draw!)
  (define ps (panels))
  (panels-sync! ps)
  (define-values (c r s) (render-display-patch ps doc-v (unbox W) (unbox H) cache))
  (set! cache c)
  (put-bytes (bytes-append (render-clear) (render-pieces (append r s))))
  (put-bytes (format-cursor-move (unbox H) 1))
  (put-string (status-line))
  (flush!))

(define (run-tui!)
  (with-tui
   (λ ()
     (cursor-hide)
     (draw!)
     (let loop ()
       (define ev (read-event))
       (cond
         [(resize-event? ev)
          (set-box! W (resize-event-cols ev))
          (set-box! H (resize-event-rows ev))
          (set! cache #f)
          (draw!)
          (loop)]
         [(null-event? ev) (loop)]
         [else
          (void (handle-event! ev))
          (draw!)
          (when (unbox running?) (loop))])))))

(module+ main
  (if (positive? (vector-length (current-command-line-arguments)))
      (run-tui!)
      (run-check!)))
