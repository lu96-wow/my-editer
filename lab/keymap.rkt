#lang racket

;;; keymap.rkt —— 键位表：token → 意图（纯数据）
;;;
;;; 一张 keymap 就是「哪些键派发成哪个 intent」的静态声明，**不存闭包、不存状态**。
;;; 于是键位可以打印、比较、继承、单测；加键只改 bindings.rkt，不动任何逻辑。
;;;
;;;   bindings  : hash(token → binding)         精确绑定
;;;   default   : binding | #f                  文本兜底（只对文本输入生效，见 dispatch）
;;;   catch-all?: bool                          模态键位：没命中的键也一律吞掉（不落给下层）
;;;
;;; 三层语义（dispatch.rkt 实现）：
;;;   1) token 精确命中 bindings        → 用该 binding
;;;   2) 否则是文本输入且有 default     → 用 default，并把输入文本并入 payload
;;;   3) 否则 catch-all? 为真           → 吞掉（返回 #f，不再往下找）
;;;   4) 否则落到下一张 keymap
;;;
;;; keymap-extend：child 覆盖 parent（绑定的键、default、catch-all 都按 child 优先）。
;;; 用来表达「基础导航 ⊕ 某文档自己的键」。

(provide (struct-out keymap) (struct-out binding)
         bind km keymap-find keymap-extend)

(struct binding (tag payload) #:transparent)
;; tag     : symbol
;; payload : list

;; 构造一个 binding。
(define (bind tag [payload '()]) (binding tag payload))

(struct keymap (name bindings default catch-all?) #:transparent)
;; name       : symbol
;; bindings   : (hash/c token binding)
;; default    : (or/c #f binding)
;; catch-all? : bool

;; 构造：pairs 每项是 (list token tag) 或 (list token tag payload)。
;;   (km 'tree (list (list 'enter 'tree/activate)
;;                   (list #\n 'tree/new-file)
;;                   (list 'C-q 'app/quit))
;;       (bind 'tree/ignore)      ; 文本兜底
;;       #f)                      ; 非模态
(define (km name pairs [default #f] [catch-all? #f])
  (keymap name
          (for/hash ([p (in-list pairs)])
            (define tag (cadr p))
            (define payload (if (null? (cddr p)) '() (caddr p)))
            (values (car p) (bind tag payload)))
          default
          catch-all?))

;; 精确查找（不含 default 兜底）。
(define (keymap-find k token)
  (hash-ref (keymap-bindings k) token #f))

;; child 覆盖 parent：绑定逐项覆盖；default / catch-all? 按 child 优先。
(define (keymap-extend parent child)
  (keymap (keymap-name child)
          (for/fold ([h (keymap-bindings parent)])
                    ([(t b) (in-hash (keymap-bindings child))])
            (hash-set h t b))
          (or (keymap-default child) (keymap-default parent))
          (or (keymap-catch-all? child) (keymap-catch-all? parent))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "key.rkt")

  (define base (km 'base (list (list 'up 'nav/up) (list 'down 'nav/down))))
  (define mine (km 'mine (list (list 'up 'my/up) (list #\n 'my/new))
                   (bind 'my/insert)))

  ;; 精确命中
  (check-equal? (binding-tag (keymap-find base 'down)) 'nav/down)
  (check-false (keymap-find base #\n))

  ;; 继承：child 覆盖同名键，parent 其余键保留，default 取 child
  (define ext (keymap-extend base mine))
  (check-equal? (binding-tag (keymap-find ext 'up)) 'my/up)
  (check-equal? (binding-tag (keymap-find ext 'down)) 'nav/down)
  (check-equal? (binding-tag (keymap-default ext)) 'my/insert)

  ;; 无 default 时继承 parent 的
  (define child2 (km 'c2 (list (list 'x 'x/x))))
  (check-equal? (binding-tag (keymap-default (keymap-extend mine child2))) 'my/insert)

  ;; payload 解析
  (define k2 (km 'k2 (list (list 'S-down 'editor/down (list #t)))))
  (check-equal? (binding-payload (keymap-find k2 'S-down)) (list #t))

  (displayln "lab/keymap.rkt: all tests passed"))
