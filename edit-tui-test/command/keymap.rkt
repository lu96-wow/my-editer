#lang racket

;;; 由 edit-tui/command/keymap.rkt 的测试外移而来（edit-tui 只留实现）。
;;; 新版：keytable = 表列表操作对象；merge 冲突报错；叶子是 command（run/note/input）。
(require rackunit
         "../../edit-tui/command/keymap.rkt"
         "../../edit-tui/command/command.rkt"
         "../../edit-tui/command/key.rkt")

(define (status kt seq)
  (call-with-values (λ () (keytable-lookup kt seq)) (λ (s _) s)))
(define (value kt seq)
  (call-with-values (λ () (keytable-lookup kt seq))
    (λ (s c) (and (eq? s 'command) ((command-run c))))))

(define base
  (keys [(key 'left)                       (λ () 'left)]
        [(key 'x 'ctrl) (key 's 'ctrl)     (λ () 'save)]
        [(key 'p 'ctrl) (key 'up)          (λ () 'focus-up)]))

(define kt (make-keytable base))

;; 查表：单键 / 多键 / 前缀未到底 / 未绑定
(check-equal? (status kt (list (key 'left))) 'command)
(check-equal? (value  kt (list (key 'left))) 'left)
(check-equal? (value  kt (list (key 'x 'ctrl) (key 's 'ctrl))) 'save)
(check-equal? (value  kt (list (key 'p 'ctrl) (key 'up))) 'focus-up)
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)
(check-equal? (status kt (list (key 'nope))) 'unbound)

;; 冲突：同一序列两个叶子
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'left) (λ () 'other)]))))
;; 冲突：叶子 vs 前缀（C-x 与 C-x C-s）
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'x 'ctrl) (λ () 'x-only)]))))
;; 冲突：前缀 vs 叶子（先有 C-x 叶子，再并入 C-x C-s）
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'y 'ctrl) (λ () 'y-only)])
                         (keys [(key 'y 'ctrl) (key 's 'ctrl) (λ () 'y-s)]))))
;; 失败是原子的：上面的失败没污染 kt
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)
(check-equal? (status kt (list (key 'y 'ctrl))) 'unbound)
(check-equal? (status kt (list (key 'y 'ctrl) (key 's 'ctrl))) 'unbound)

;; 不冲突：同前缀、不同续键都能留下
(void (keytable-merge! kt (keys [(key 'x 'ctrl) (key 'c 'ctrl) (λ () 'quit)])))
(check-equal? (value kt (list (key 'x 'ctrl) (key 's 'ctrl))) 'save)
(check-equal? (value kt (list (key 'x 'ctrl) (key 'c 'ctrl))) 'quit)
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)

;; 批次一起并：新表之间也要查冲突（且整体原子）
(define kt2 (make-keytable))
(check-exn exn:fail?
  (λ () (keytable-merge! kt2
                         (keys [(key 'q) (λ () 1)])
                         (keys [(key 'q) (λ () 2)]))))
(check-equal? (status kt2 (list (key 'q))) 'unbound)

;; 运行时动态修改：空表 → 并表后立即可查
(define kt3 (make-keytable))
(check-equal? (status kt3 (list (key 'a))) 'unbound)
(void (keytable-merge! kt3 (keys [(key 'a) (λ () 'a)])))
(check-equal? (value kt3 (list (key 'a))) 'a)
;; 整份替换也可（结构体是 mutable 的）
(set-keytable-tables! kt3 '())
(check-equal? (status kt3 (list (key 'a))) 'unbound)

;; keys 产出的仍是一张普通表；make-keytable 可直接带初值
(check-equal? (value (make-keytable base) (list (key 'left))) 'left)

;;; ──────────────────────── command：note / input ────────────────────────

(define kt4
  (make-keytable
   (keys [(key 'x 'ctrl) (key 's 'ctrl) (cmd #:note "保存" (λ () 'save))]
         [(key 'x 'ctrl) (key 'c 'ctrl) (cmd #:note (λ () "退出（动态说明）") (λ () 'quit))]
         [(key 'f 'ctrl) (key 'x 'ctrl)
          (cmd #:note "另存为"
               #:input (input 'string "文件名: " #f)
               (λ (path) path))]))) 

;; note 是 command 自身带的，随查表结果一起回来
(check-false (cdr (assoc (key 'x 'ctrl) (keytable-hints kt4 '())))) ; 前缀那格没有叶子
(define-values (s-save c-save) (keytable-lookup kt4 (list (key 'x 'ctrl) (key 's 'ctrl))))
(check-equal? (command-note-string c-save) "保存")
(define-values (s-quit c-quit) (keytable-lookup kt4 (list (key 'x 'ctrl) (key 'c 'ctrl))))
(check-equal? (command-note-string c-quit) "退出（动态说明）")

;; input spec：需要输入 + 提示语；宿主收完再 (run value)
(define-values (s-input c-input) (keytable-lookup kt4 (list (key 'f 'ctrl) (key 'x 'ctrl))))
(check-equal? s-input 'command)
(check-true (command-needs-input? c-input))
(check-equal? (input-prompt (command-input c-input)) "文件名: ")
(check-equal? ((command-run c-input) "/tmp/a") "/tmp/a")
;; 无 input 的直接执行
(check-false (command-needs-input? c-save))

;; which-key：当前前缀下紧接一步的选项（含说明）
(check-equal? (map (λ (h) (list (key->string (car h)) (and (cdr h) (command-note-string (cdr h)))))
                   (keytable-hints kt4 (list (key 'x 'ctrl))))
              '(("C-c" "退出（动态说明）") ("C-s" "保存")))
(check-equal? (map (λ (h) (key->string (car h)))
                   (keytable-hints kt4 '()))
              '("C-f" "C-x"))

;; 帮助 / 补全：当前前缀下所有完整绑定
(check-equal? (map (λ (p) (map key->string (car p)))
                   (keytable-commands kt4 (list (key 'x 'ctrl))))
              '(("C-x" "C-c") ("C-x" "C-s")))

;;; ──────────────────────── 纯 matcher：正在匹配的序列 ────────────────────────

(define m (make-matcher kt))
(check-equal? (call-with-values (λ () (matcher-feed! m (key 'x 'ctrl))) list)
              (list 'prefix #f))
(check-equal? (matcher-pending m) (list (key 'x 'ctrl)))       ; ← 正在匹配的序列
(define-values (mst mcmd) (matcher-feed! m (key 's 'ctrl)))
(check-equal? mst 'command)
(check-equal? ((command-run mcmd)) 'save)
(check-false (matcher-pending m))                               ; 命中后清空
;; unbound 也清空
(begin (matcher-feed! m (key 'x 'ctrl)) (void))
(check-equal? (matcher-pending m) (list (key 'x 'ctrl)))
(check-equal? (call-with-values (λ () (matcher-feed! m (key 'nope))) list)
              (list 'unbound #f))
(check-false (matcher-pending m))

;; 运行时并表，matcher 立刻看到（持同一个 keytable）
(define kt-m (make-keytable (keys [(key 'a) (λ () 'a)])))
(define m2 (make-matcher kt-m))
(void (keytable-merge! kt-m (keys [(key 'b) (λ () 'b)])))
(define-values (s-b c-b) (matcher-feed! m2 (key 'b)))
(check-equal? s-b 'command)
(check-equal? ((command-run c-b)) 'b)

(displayln "edit-tui/command/keymap.rkt: ok")
