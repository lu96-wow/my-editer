#lang racket

;;; lab-rebuild/platform/keymap.rkt —— keymap 机制（平台骨架）
;;;
;;; keymap = binding -> command spec 的映射，分两种用法：
;;;   · 命名 keymap：进全局 registry，按名字唯一；**可变**，加载后仍能增删绑定。
;;;     这是「包往已有键表追加绑定」（Emacs `define-key`）的实现基础。
;;;   · 匿名 keymap：`(command-table binding spec …)` 构造的纯值，用于前缀键
;;;     或临时合成（`command-merge`）。
;;;
;;; command-set = 全局 keymap 列表 + 每 did 的 keymap 列表；dispatch 按
;;; global → did → mode(extra) 顺序查找，后命中的覆盖先命中的。
;;;
;;; 为什么命名 keymap 要可变：包（树 / 补全 / …）在加载后才能注册自己的模式键表，
;;; 而且可能想往 `'edit` / `'global` 里补键。若 keymap 是不可变值，command-set
;;; 捕获的是旧快照，运行时的 `keymap-add!` 不会生效。这里让 struct 原地可变，
;;; command-set 持有的是同一个对象，于是追加立即对所有查表可见。

(provide keymap? keymap-name keymap-bindings
         command-table
         keymap-define keymap-ensure! keymap-ref
         keymap-add! keymap-remove! keymap-merge-into!
         keymap-bound? keymap-empty? keymap-events
         command-merge command-lookup
         command-set command-set? command-set-global command-set-docs
         command-set-add-doc command-set-set-doc command-set-doc-tables command-set-tables
         command-set-lookup)

;;; ================= 单表 =================

(struct keymap (name bindings) #:mutable #:transparent)
;; name     : symbol | #f（匿名）
;; bindings : 不可变 hash，binding -> spec

;; 匿名 keymap（纯值，不进 registry）。参数交替：binding spec binding spec …
(define (command-table . kvs)
  (keymap-from-kvs #f kvs))

(define (keymap-from-kvs name kvs)
  (unless (even? (length kvs))
    (error 'command-table "参数要成对：binding spec …，得到 ~a 个" (length kvs)))
  (keymap name
          (for/fold ([h (hash)]) ([i (in-range 0 (length kvs) 2)])
            (hash-set h (list-ref kvs i) (list-ref kvs (+ i 1))))))

;;; ================= 命名 registry =================

(define registry (make-hash))           ; symbol -> keymap

;; 取-or-建命名 keymap。
(define (keymap-ensure! name)
  (unless (symbol? name) (error 'keymap-ensure! "名字必须是 symbol，得到 ~a" name))
  (or (hash-ref registry name #f)
      (let ([km (keymap name (hash))])
        (hash-set! registry name km)
        km)))

(define (keymap-ref name) (hash-ref registry name #f))

;; 取-or-建命名 keymap，并把 kv 对追加进去。name = #f → 匿名新建。
;; 返回该 keymap。（可反复调用：已有绑定被同 binding 覆盖。）
(define (keymap-define name . kvs)
  (cond
    [(not name) (keymap-from-kvs #f kvs)]
    [(symbol? name)
     (define km (keymap-ensure! name))
     (unless (even? (length kvs))
       (error 'keymap-define "参数要成对：binding spec …，得到 ~a 个" (length kvs)))
     (for ([i (in-range 0 (length kvs) 2)])
       (keymap-add! km (list-ref kvs i) (list-ref kvs (+ i 1))))
     km]
    [else (error 'keymap-define "name 必须是 symbol 或 #f，得到 ~a" name)]))

;;; ================= 增删查（可直接作用于 keymap 对象） =================

(define (keymap-add! km b spec)
  (unless (keymap? km) (error 'keymap-add! "需要 keymap，得到 ~a" km))
  (set-keymap-bindings! km (hash-set (keymap-bindings km) b spec)))

(define (keymap-remove! km b)
  (unless (keymap? km) (error 'keymap-remove! "需要 keymap，得到 ~a" km))
  (set-keymap-bindings! km (hash-remove (keymap-bindings km) b)))

;; 把 source 的所有绑定并进 target（source 覆盖同名）；返回 target。
(define (keymap-merge-into! target source)
  (unless (and (keymap? target) (keymap? source))
    (error 'keymap-merge-into! "需要两个 keymap，得到 ~a / ~a" target source))
  (for ([(b spec) (in-hash (keymap-bindings source))])
    (keymap-add! target b spec))
  target)

(define (keymap-bound? km b) (hash-has-key? (keymap-bindings km) b))
(define (keymap-empty? km) (zero? (hash-count (keymap-bindings km))))
(define (keymap-events km) (hash-keys (keymap-bindings km)))

;;; ================= 合成与查找 =================

;; 把一串 keymap 合成一个匿名 keymap（后面的覆盖前面的）。
(define (command-merge kms)
  (keymap #f
          (for/fold ([h (hash)]) ([km (in-list kms)])
            (for/fold ([h h]) ([(b spec) (in-hash (keymap-bindings km))])
              (hash-set h b spec)))))

;; tables : (listof keymap)，后面的优先级高。从后往前，返回第一个命中的 spec。
(define (command-lookup tables b)
  (for/or ([km (in-list (reverse tables))])
    (hash-ref (keymap-bindings km) b #f)))

;;; ================= document 关联的命令集 =================

(struct command-set% (global docs) #:transparent)
;; global : (listof keymap)                所有文档都生效
;; docs   : 不可变 hash did -> (listof keymap)

(define (command-set [global '()]) (command-set% global (hash)))
(define (command-set? x) (command-set%? x))
(define (command-set-global cs) (command-set%-global cs))
(define (command-set-docs cs) (command-set%-docs cs))

(define (command-set-set-doc cs did tables)
  (command-set% (command-set-global cs) (hash-set (command-set-docs cs) did tables)))
(define (command-set-add-doc cs did t)
  (command-set-set-doc cs did (append (command-set-doc-tables cs did) (list t))))
(define (command-set-doc-tables cs did)
  (hash-ref (command-set-docs cs) did '()))

;; 某文档实际生效的表：global + 该 did 自己的。
(define (command-set-tables cs did)
  (append (command-set-global cs) (command-set-doc-tables cs did)))

(define (command-set-lookup cs did b) (command-lookup (command-set-tables cs did) b))
