#lang racket

;;; 事件循环：step / command / action / engine / render / run-loop。

(require rackunit
         "../main.rkt")

(define area (rect 0 0 20 5))

;;; ---------- 命令 ----------
(define (cmd-insert state)
  (values state (list (view-action 'insert 1 #"A"))))

(define (cmd-seq state)
  (values (struct-copy app-state state [flash "seq"]) '()))

(define (cmd-quit state)
  (values state (list (quit-action))))

(define table
  (keys
   [(key 'a) cmd-insert]
   [(key 'x) (key 's) cmd-seq]
   [(key 'q) cmd-quit]))

;;; ---------- resource + engine ----------
(define engine (make-engine))
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "main"
                 #:text "hello"
                 #:tables (list table)))
(define rid 1)
(define vid 1)

;;; ---------- layout：一个 editor panel，content 用 view-id ----------
(define editor-panel
  (make-panel 'editor 'editor
              #:views (list vid)
              #:active vid))
(define layout
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor editor-panel)
               #:focus 'editor))

(define state
  (make-app-state #:layout layout
                  #:resources store
                  #:focus-resource rid
                  #:area area))

(define state1 (run-actions state engine actions))
(check-equal? (engine-view-text engine vid) "hello")
(let-values ([(_c _b) (render-frame state1 engine #f)]) (void))  ; 首帧同步 view 尺寸

;;; ---------- key -> command -> action ----------
(define-values (state2 acts2) (step state1 (key-event (key 'a))))
(check-equal? (map view-action? acts2) '(#t))
(define state3 (run-actions state2 engine acts2))
(check-equal? (engine-view-text engine vid) "Ahello")

;;; ---------- 键序列 ----------
(define-values (state4 acts4) (step state3 (key-event (key 'x))))
(check-equal? acts4 '())
(check-equal? (app-state-pending state4) (list (key 'x)))
(define-values (state5 acts5) (step state4 (key-event (key 's))))
(check-equal? (app-state-flash state5) "seq")
(check-equal? (app-state-pending state5) '())

;;; ---------- unbound（不可打印 / 带修饰的键不走自插入兜底） ----------
(define-values (state6 acts6) (step state5 (key-event (key 'z 'ctrl))))
(check-equal? acts6 '())
(check-true (string-contains? (app-state-flash state6) "unbound"))
(check-equal? (app-state-pending state6) '())

;;; ---------- flash 只存在到下一次 step ----------
(define-values (state6b _acts6b) (step state6 (key-event (key 'x))))
(check-equal? (app-state-flash state6b) "")
(check-equal? (app-state-pending state6b) (list (key 'x)))

;;; ---------- paste ----------
(define-values (state7 acts7) (step state6 (paste-event #"!")))
(check-equal? (map view-action? acts7) '(#t))
(define state8 (run-actions state7 engine acts7))
(check-equal? (engine-view-text engine vid) "A!hello")

;;; ---------- resize ----------
(define-values (state9 acts9) (step state8 (resize-event 10 40)))
(check-equal? acts9 '())
(check-equal? (app-state-area state9) (rect 0 0 40 10))

;;; ---------- render ----------
(define-values (_cache bytes) (render-frame state8 engine #f))
(check-true (string-contains? (bytes->string/utf-8 bytes) "A!"))

;;; ---------- run-loop ----------
(define events (box (list (key-event (key 'a)) (quit-event))))
(define (next-event)
  (define xs (unbox events))
  (set-box! events (cdr xs))
  (car xs))
(define out (open-output-bytes))
(define final
  (run-loop state8 engine
            #:read-event next-event
            #:write-bytes (λ (b) (write-bytes b out))))
(check-true (app-state-quit? final))
(check-true (> (bytes-length (get-output-bytes out)) 0))
(check-equal? (engine-view-text engine vid) "A!Ahello")

;;; ---------- 可打印字符兜底自插入（大写保留） ----------
(define-values (stateA actsA) (step final (key-event (key 'Q))))
(check-equal? (map view-action-kind actsA) '(insert))
(define finalA (run-actions stateA engine actsA))
(check-equal? (engine-view-text engine vid) "A!AQhello")

(displayln "edit-tui-rebuild/test/event-loop.rkt: ok")
