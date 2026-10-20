#lang racket

;;; 输入栏：单行编辑（光标 / 插入 / 删除 / Home End）+ prompt 校验。
;;; 退出保存流程见 test/quit-save.rkt。

(require rackunit
         racket/file
         "../config/keymap/default.rkt"
         "../main.rkt")

;;; ════════════════ 最小 app：editor + status/input ════════════════

(define (make-app text)
  (define engine (make-engine))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "main"
                   #:text text
                   #:tables (keymap-editor-tables default-keymap)))
  (define rid (resource-id (car (resource-list store))))
  (void (run-actions (make-app-state) engine actions))
  ;; status / input 的 view
  (void (engine-create-buffer! engine 20 "*status*" ""))
  (void (engine-create-view! engine 20 20))
  (void (engine-create-buffer! engine 21 "*input*" ""))
  (void (engine-create-view! engine 21 21))
  (define editor-panel
    (make-panel 'editor 'editor #:views (list 1) #:active 1
                #:borders '(up down left right)))
  (define status-panel
    (make-panel 'status 'status #:views '(20 21) #:active 20
                #:fixed-h 1 #:borders '(up)))
  (define layout
    (let-values ([(l1 ok1?) (layout-panel-attach
                             (make-layout #:root (make-leaf 'editor)
                                          #:panels (hash 'editor editor-panel)
                                          #:focus 'editor)
                             'editor 'down status-panel)])
      (check-true ok1?)
      l1))
  (define state (make-app-state #:layout layout
                                #:resources store
                                #:focus-resource rid
                                #:keymap default-keymap
                                #:area (rect 0 0 60 8)))
  (define s1 (status-install-state state 20))
  (define s2 (input-install-state s1 'status 20 21))
  (define s3 (run-actions s2 engine actions))
  (let-values ([(cache bytes) (render-frame s3 engine #f)])   ; 落 viewport 尺寸
    (void cache)
    (void bytes))
  (values s3 engine rid))

(define (sync! state engine)
  (define s (sync-ui! state engine))
  (let-values ([(c b) (render-frame s engine #f)]) (void c) (void b))
  s)

(define (press/actions state engine tok)
  (define-values (s a) (step state (key-event tok)))
  (values (sync! (run-actions s engine a) engine) a))

(define (press state engine tok)
  (let-values ([(s a) (press/actions state engine tok)]) (void a) s))

(define (type state engine str)
  (for/fold ([s state]) ([c (in-string str)])
    (press s engine (key c))))

(define (view-line engine vid)
  (engine-view-text engine vid))

(define prefix "Save as: ")

;;; ════════════════ save-path：光标编辑 ════════════════

(define-values (s0 e0 r0) (make-app "hello"))
(define-values (store*0 acts0) (resource-save (app-state-resources s0) r0))
(check-equal? acts0 '())
(check-equal? (prompt-kind (resource-prompt store*0)) 'save-path)
(define s1 (sync! (struct-copy app-state s0 [resources store*0]) e0))
(check-true (input-active? s1))
;; 提示真的画出来了（viewport 尺寸必须先于内容同步，否则会水平滚过头）
(let-values ([(cache bytes) (render-frame s1 e0 #f)])
  (void cache)
  (check-true (string-contains? (bytes->string/utf-8 bytes) prefix)))

(define s2 (type s1 e0 "abc"))
(check-equal? (view-line e0 21) (string-append prefix "abc"))

;; 输入栏专属：C-h -> head，C-t -> tail（C-h 在输入栏不是 Backspace）
(define s2h (press s2 e0 (key 'h 'ctrl)))
(check-equal? (view-line e0 21) (string-append prefix "abc"))
(check-equal? (engine-view-point-column e0 21) 0)
(define s2t (press s2h e0 (key 't 'ctrl)))
(check-equal? (engine-view-point-column e0 21)
              (string-length (string-append prefix "abc")))

;; ← ← 后插入 X -> aXbc
(define s3 (press s2t e0 (key 'left)))
(define s4 (press s3 e0 (key 'left)))
(define s5 (type s4 e0 "X"))
(check-equal? (view-line e0 21) (string-append prefix "aXbc"))

;; Home / C-a 到行首，插入 !；再 End 到行尾
(define s6 (press s5 e0 (key 'home)))
(define s7 (type s6 e0 "!"))
(check-equal? (view-line e0 21) (string-append prefix "!aXbc"))
(define s8 (press s7 e0 (key 'e 'ctrl)))
;; Backspace 删光标前（行尾 -> 删 c）
(define s9 (press s8 e0 (key 'backspace)))
(check-equal? (view-line e0 21) (string-append prefix "!aXb"))
;; Delete 删光标处（行尾 -> 不变）
(define s10 (press s9 e0 (key 'delete)))
(check-equal? (view-line e0 21) (string-append prefix "!aXb"))
;; Home 到整行行首（前缀里，光标可见 prompt）；Delete 不碰前缀
(define s11 (press s10 e0 (key 'home)))
(check-equal? (engine-view-point-column e0 21) 0)
(define s11b (press s11 e0 (key 'delete)))
(check-equal? (view-line e0 21) (string-append prefix "!aXb"))
;; → 走到文本起点，再 Delete 删第一个字符
(define s11c (for/fold ([s s11b]) ([i (in-range (string-length prefix))])
               (press s e0 (key 'right))))
(define s12 (press s11c e0 (key 'delete)))
(check-equal? (view-line e0 21) (string-append prefix "aXb"))

;;; ════════════════ 粘贴：只取单行可打印内容 ════════════════

(define s12b (press s12 e0 (key 'end)))
(define-values (s12c pa) (step s12b (paste-event (string->bytes/utf-8 "a\nb"))))
(check-equal? pa '())
(define s12d (sync! s12c e0))
(check-equal? (view-line e0 21) (string-append prefix "aXbab"))

;;; ════════════════ 空路径不提交 ════════════════

;; 清空输入（End 后删到只剩前缀）
(define (clear-input state)
  (let loop ([s (press state e0 (key 'end))])
    (if (string=? prefix (view-line e0 21))
        s
        (loop (press s e0 (key 'backspace))))))
(define s14 (clear-input s12d))
(define-values (s15 a15) (press/actions s14 e0 (key 'enter)))
(check-equal? a15 '())
(check-true (input-active? s15))
(check-true (string-contains? (app-state-flash s15) "path required"))
(check-not-false (resource-prompt (app-state-resources s15)))

;;; ════════════════ 写文件 ════════════════

(define path "tmp-input-test.txt")
(when (file-exists? path) (delete-file path))
(define s16 (type s15 e0 path))
(define-values (s17 a17) (press/actions s16 e0 (key 'enter)))
(check-equal? (map resource-action-kind a17) '(write-file))
(define s18 (run-actions s17 e0 a17))
(check-true (file-exists? path))
(check-false (input-active? (sync! s18 e0)))
(check-equal? (resource-path (app-state-resources s18) r0) path)
(check-false (resource-dirty? (app-state-resources s18) r0))
(delete-file path)

;;; ════════════════ 打开输入时清空 pending ════════════════

;; 模拟先按了 C-w 还没按方向键（pending），随后 prompt 打开；
;; 第一键应按单键查 input 表，而不是拼成 (C-w key)。
(define-values (p0 pe0 pr0) (make-app "hello"))
(define p1 (struct-copy app-state p0 [pending (list (key 'w 'ctrl))]))
(define-values (pstore _pa) (resource-save (app-state-resources p1) pr0))
(define p2 (sync! (struct-copy app-state p1 [resources pstore]) pe0))
(check-true (input-active? p2))
(check-equal? (app-state-pending p2) '())
(define p3 (press p2 pe0 (key 'x)))
(check-equal? (view-line pe0 21) (string-append prefix "x"))

(displayln "edit-tui-rebuild/test/input.rkt: ok")
