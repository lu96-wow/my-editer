#lang racket

;;; edit-rebuild/plugins/highlight/words.rkt —— 词高亮插件（输入时不变色）
;;;
;;; 色 = 词名的纯函数（djb2 散列 → 色板下标）：同词同色、跨文件 / 会话稳定。
;;;
;;; 唯一的状态是「正在输入的词」= 上次编辑插入点所在的 token：
;;;   · change 时由 changes 算得（**只看编辑点，不看光标**）；
;;;   · 该词本次**不上色**，其余照常上色 → 输入过程中色不闪；
;;;   · 下一次编辑（无论在哪）重扫它的行 → 它按完整词重新上色。
;;; 光标移动不触发插件，所以「把光标移到词上」不会改色。

(require "../../core/extension/face-plugin.rkt"
         "../../core/extension/spec.rkt"
         "../../core/face/lex.rkt"
         "../../core/face/kind.rkt"
         "../../core/face/face.rkt"
         "../../core/face/line-scan.rkt"
         "../config/words.rkt")

(provide word-plugin word-spec)

;; 稳定散列（djb2）：跨会话 / 跨 place 一致，不依赖 equal-hash-code 的随机性。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (word-face w)
  (palette-color 'word (modulo (word-hash w) (max 1 word-color-count))))

;; 行 → face 向量（无词 → #f）。pending = (list line start end) | #f，跳过它。
(define (word-line pending line-no line)
  (define n (string-length line))
  (define faces (make-vector n #f))
  (define touched? #f)
  (for ([m (in-list (line-tokens line))])
    (define start (car m))
    (define end (cdr m))
    (unless (and pending (= line-no (car pending)) (= start (cadr pending)))
      (set! touched? #t)
      (define f (word-face (substring line start end)))
      (for ([i (in-range start end)]) (vector-set! faces i f))))
  (and touched? faces))

;; open：没有「正在输入的词」，整篇上色。
(define (word-open text _path)
  (values #f (scan-track text (lambda (ln line) (word-line #f ln line)))))

(define (word-change pending layer ctx)
  (define new-text (face-ctx-new-text ctx))
  (define changes (face-ctx-changes ctx))
  (define new-pending (edit-word changes new-text))
  (define old-line (and pending (car pending)))
  (define new-line (and new-pending (car new-pending)))
  (values new-pending
          (refresh-layer layer new-text changes
                         (filter values (list old-line new-line))
                         (lambda (ln line) (word-line new-pending ln line)))
          (dirty-union (face-ctx-dirty ctx)
                       (dirty-lines (filter values (list old-line new-line))))))

(define word-plugin
  (face-plugin 'words racket-applies? word-open word-change))

(define word-spec
  (plugin-spec 'words (lambda (s) s) (list word-plugin)))
