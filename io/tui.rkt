#lang racket

(require tui
         "../core/api.rkt")

;;; io/tui.rkt —— racket-tui 与 core 的两个连接点
;;;
;;;   输入连接：racket-tui 的 raw (type data mods) → core 的类型化 event
;;;   渲染连接：core 的 screen → ANSI bytes（theme 查 face → 颜色）
;;;
;;; 全项目唯一 require racket-tui 的地方。core 不认识任何终端细节。

(provide tui-run
         screen->bytes)

;;; ============ 渲染连接：core screen → ANSI bytes ============

(define (attr->thunk a)
  (case a
    [(bold) attr-bold]
    [(dim) attr-dim]
    [(italic) attr-italic]
    [(underline) attr-underline]
    [(reverse) attr-reverse]
    [(blink) attr-blink]
    [else (error 'attr->thunk "unknown attribute ~a" a)]))

;; 中性样式 spec = (list r g b attr...)；text → ANSI 字节
(define (spec->bytes spec text)
  (match spec
    [(list r g b attrs ...)
     (define style
       (call-with-output-bytes
        (λ (out)
          (parameterize ([current-output-port out])
            ((color-rgb-fg r g b))
            (for ([a (in-list attrs)]) ((attr->thunk a)))))))
     (bytes-append style (format-content text) format-reset)]
    [_ (format-content text)]))

;; run 的 face 是语义符号（'keyword/'string/...），查 theme 拿中性样式
(define (run->bytes theme row r)
  (define face (hash-ref (run-face r) 'face #f))
  (define spec (and face (hash-ref theme face #f)))   ; 查不到 → 纯文本
  (bytes-append
   (format-cursor-move (add1 row) (add1 (run-col r))) ; 0-based → 1-based
   (if spec (spec->bytes spec (run-text r)) (format-content (run-text r)))))

(define (row->bytes theme scr row)
  (apply bytes-append
         (for/list ([r (in-list (vector-ref (screen-row-runs scr) row))])
           (run->bytes theme row r))))

(define (cursor-bytes scr)
  (if (and (<= 0 (screen-cursor-row scr) (sub1 (screen-rows scr)))
           (<= 0 (screen-cursor-col scr) (sub1 (screen-cols scr))))
      (bytes-append
       (format-cursor-move (add1 (screen-cursor-row scr)) (add1 (screen-cursor-col scr)))
       format-cursor-show)
      format-cursor-hide))

;; changed = #f → 全量（首帧/尺寸变化，先清屏）；否则只重画变化行
(define (screen->bytes theme scr changed)
  (define rows (screen-rows scr))
  (define full? (not changed))
  (bytes-append
   format-cursor-hide
   (if full? format-screen-clear (bytes))
   (apply bytes-append
          (for/list ([row (if full? (range rows) changed)])
            (bytes-append
             (format-cursor-move (add1 row) 1)
             format-line-clear
             (row->bytes theme scr row))))
   (cursor-bytes scr)))

;;; ============ 输入连接：racket-tui raw → core event ============

(define no-mods (modifiers #f #f #f #f))

;; 事件解码器工厂：返回 (type data mods) -> event 的函数。
;; build-input 是回调式的（只调你给的 callback，不返回值），
;; 用 box 把回调的副作用接回成返回值，让调用方拿到一个 event。
(define (make-event-decoder)
  (define ev (box #f))
  (define emit (λ (e) (set-box! ev e)))
  (define dispatch
    (build-input
     #:utf-char  (λ (s)  (emit (text-event s no-mods)))
     #:char      (λ (ch) (emit (text-event (string (integer->char ch)) no-mods)))
     #:tab       (λ ()   (emit (key-event 'tab no-mods)))
     #:enter     (λ ()   (emit (key-event 'enter no-mods)))
     #:backspace (λ ()   (emit (key-event 'backspace no-mods)))
     #:delete    (λ ()   (emit (key-event 'delete no-mods)))
     #:escape    (λ ()   (emit (key-event 'escape no-mods)))
     #:up        (λ ()   (emit (key-event 'up no-mods)))
     #:down      (λ ()   (emit (key-event 'down no-mods)))
     #:left      (λ ()   (emit (key-event 'left no-mods)))
     #:right     (λ ()   (emit (key-event 'right no-mods)))
     #:home      (λ ()   (emit (key-event 'home no-mods)))
     #:end       (λ ()   (emit (key-event 'end no-mods)))
     #:ctrl      (λ (ch) (emit (key-event ch (modifiers #t #f #f #f))))
     #:resize    (λ (r c) (emit (resize-event r c)))
     #:paste     (λ (data) (emit (text-event (bytes->string/utf-8 data) no-mods)))
     #:any       (λ (t d m) (void))))
  (λ (type data mods)
    (set-box! ev #f)
    (dispatch type data mods)
    (unbox ev)))

;;; ============ 主循环（render → draw → read → handle）============

;; make-state : (rows cols) -> state0
;; render     : state -> screen
;; handle     : state event -> (values state done?)
(define (tui-run theme make-state render handle)
  (tui-init)
  (define decoder (make-event-decoder))
  (define-values (r0 c0) (get-window-size))
  (let loop ([state (make-state (or r0 24) (or c0 80))] [prev #f])
    (define scr (render state))
    ;; 首帧或尺寸变化 → 全量；否则只挑变化行（screen-diff-rows 要求同尺寸）
    (define changed
      (cond [(not prev) #f]
            [(and (= (screen-rows prev) (screen-rows scr))
                  (= (screen-cols prev) (screen-cols scr)))
             (screen-diff-rows prev scr)]
            [else #f]))
    (put-bytes (screen->bytes theme scr changed))
    (define-values (type data mods) (read-event))
    (define ev (decoder type data mods))
    (cond
      [(not ev) (loop state scr)]              ; 未识别的事件 → 忽略
      [else
       (define-values (state* done?) (handle state ev))
       (if done? (tui-exit) (loop state* scr))])))

;;; ============ 测试（只测纯函数，不碰终端）============

(module+ test
  (require rackunit)

  (define theme (hash 'keyword '(97 175 239)))

  ;; 输入连接：raw → 类型化 event（用主循环同一个解码器）
  (define decoder (make-event-decoder))
  (check-equal? (decoder 'up #f #f) (key-event 'up no-mods))
  ;; Enter 在 tui 里是 'key 类型 + 单字节 CR(13)/LF(10)，由 build-input 分派到 #:enter
  (check-equal? (decoder 'key (bytes 13) #f) (key-event 'enter no-mods))
  (check-equal? (decoder 'utf8 #"hi" #f) (text-event "hi" no-mods))
  (check-equal? (decoder 'resize '(30 . 100) #f) (resize-event 30 100))

  ;; 渲染连接：screen → ANSI（关键字带颜色、光标定位正确）
  (define s (screen 1 10 (vector (list (run 0 "hi" (hash 'face 'keyword)))) 0 2))
  (define txt (bytes->string/utf-8 (screen->bytes theme s '(0))))
  (check-true (regexp-match? #rx"hi" txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;3H") txt))  ; 光标 (0,2) → 1-based (1,3)

  ;; 未注册 face → 纯文本
  (define s2 (screen 1 10 (vector (list (run 0 "x" (hash 'face 'unknown)))) 0 0))
  (check-true (regexp-match? #rx"x" (bytes->string/utf-8 (screen->bytes theme s2 '(0)))))

  (displayln "tui.rkt: all tests passed"))
