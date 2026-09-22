#lang racket

(require "point.rkt" "edit.rkt" "selection.rkt" rackunit)

;;; atom/selection-set.rkt —— 命名选区集
;;;
;;;   selection-set = name ⊕ selections ⊕ leader-index
;;;
;;; 一组区间（多选区）+ 名字 + 一个 leader（「原来的单选区」）——就是插入/删除作用的**操作对象**。
;;; **纯值 + 代数**：core 不决定何时收敛；上层持有选区集、对它做插入/删除（经 editor 命令），
;;; 自己调用 selection-set-clear 收敛回单个选区。
;;;
;;; selections 始终规范化（排序 / 去重 / 重叠合并）；leader 用下标表达，跨规范化由
;;; selections-primary-index 追踪（半开边界不歧义：caret 不会被前一个区间吃掉）。
;;;
;;; 依赖：point / edit / selection —— 不认识 window / document。

(provide
 selection-set?
 selection-set-name
 selection-set-selections
 selection-set-leader-index
 selection-set-open
 selection-set-normalize
 selection-set-leader
 selection-set-put-leader
 selection-set-add
 selection-set-remove
 selection-set-map
 selection-set-clear
 selection-set-map-edit
 selection-set-advance-leader)

;;; ---------- 数据 ----------

(struct selection-set (name selections leader-index) #:transparent)
;; name         : (or/c symbol? #f)               名字（“命名”）；#f = 匿名/已清除
;; selections   : (nonempty-listof selection)     已规范化
;; leader-index : nat                              leader 在 selections 里的下标

;;; ---------- 构造 / 规范化 ----------
;; leader-index 是**输入** selections 里的下标；规范化（排序/合并）后追到对应项。

(define (selection-set-open name sels [leader-index 0])
  (unless (pair? sels) (error 'selection-set-open "至少一个选区，得到 ~a" sels))
  (define idx0 (max 0 (min leader-index (sub1 (length sels)))))
  (define target (list-ref sels idx0))
  (define norm (selections-normalize sels))
  (selection-set name norm (selections-primary-index norm target)))

(define (selection-set-normalize g)
  (selection-set-open (selection-set-name g)
              (selection-set-selections g)
              (selection-set-leader-index g)))

;;; ---------- 读 ----------

;; leader 选区**值**（“原来的单选区”）。
(define (selection-set-leader g)
  (list-ref (selection-set-selections g) (selection-set-leader-index g)))

;;; ---------- 变更 ----------

;; 让集合中等于 s 的选区成为 leader（不在集合中则原样）。
(define (selection-set-put-leader g s)
  (define idx (for/first ([x (in-list (selection-set-selections g))] [i (in-naturals)]
                          #:when (equal? x s)) i))
  (if idx (selection-set (selection-set-name g) (selection-set-selections g) idx) g))

;; 并集；leader 保持（新加的追加在后面，原 leader 下标仍有效）。
(define (selection-set-add g sels)
  (selection-set-open (selection-set-name g)
              (append (selection-set-selections g) sels)
              (selection-set-leader-index g)))

;; 差集；leader 尽量保持，删空则原样。
(define (selection-set-remove g drops)
  (define sels (selection-set-selections g))
  (define target (selection-set-leader g))
  (define kept (remove* drops sels))
  (cond
    [(null? kept) g]
    [else
     (define idx (or (for/first ([x (in-list kept)] [i (in-naturals)]
                                 #:when (equal? x target)) i)
                     0))
     (selection-set-open (selection-set-name g) kept idx)]))

;; 对每个选区施加 f（selection → selection）；leader 跟随。
(define (selection-set-map g f)
  (selection-set-open (selection-set-name g)
              (map f (selection-set-selections g))
              (selection-set-leader-index g)))

;;; ---------- 清除 / 编辑后重定位 ----------

;; 清除：收敛为**单个**选区（leader），名字丢弃。上层决定何时调用。
(define (selection-set-clear g)
  (selection-set-open #f (list (selection-set-leader g)) 0))

;; 编辑后重定位（free 语义）：每个选区端点过 descs。
(define (selection-set-map-edit g descs)
  (selection-set-open (selection-set-name g)
              (for/list ([s (in-list (selection-set-selections g))])
                (for/fold ([s s]) ([d (in-list descs)]) (selection-map-edit d s)))
              (selection-set-leader-index g)))

;; 编辑后重定位（leader 语义）：每个选区坍缩到 head 并前进到插入之后。
(define (selection-set-advance-leader g descs)
  (selection-set-open (selection-set-name g)
              (for/list ([s (in-list (selection-set-selections g))])
                (caret (edits-map-position descs (selection-head s))))
              (selection-set-leader-index g)))

;;; ---------- 测试 ----------

(module+ test
  (define (P l c) (point l c))
  (define s1 (selection (P 0 0) (P 0 3)))
  (define s2 (selection (P 0 8) (P 0 11)))
  (define s3 (selection (P 0 16) (P 0 19)))

  ;; 构造：规范化 + leader 下标
  (define g (selection-set-open 'g (list s1 s2 s3) 1))
  (check-equal? (selection-set-name g) 'g)
  (check-equal? (selection-set-selections g) (list s1 s2 s3))
  (check-equal? (selection-set-leader g) s2)
  (check-equal? (selection-set-leader-index g) 1)

  ;; 重叠合并后 leader 追到包络
  (define g2 (selection-set-open 'x (list (selection (P 0 0) (P 0 4)) (selection (P 0 2) (P 0 6))) 1))
  (check-equal? (length (selection-set-selections g2)) 1)
  (check-equal? (selection-set-leader g2) (selection (P 0 0) (P 0 6)))

  ;; 边界不歧义：[0,2) 与 caret(2) 并存，leader=caret 不得归给 [0,2)
  (define gc (selection-set-open 'c (list (selection (P 0 0) (P 0 2)) (caret (P 0 2))) 1))
  (check-equal? (selection-set-leader gc) (caret (P 0 2)))

  ;; 增 / 删 / 设 leader / map；名字保持
  (check-equal? (selection-set-selections (selection-set-add (selection-set-open 'g (list s1) 0) (list s2)))
                (list s1 s2))
  (check-equal? (selection-set-name (selection-set-add g (list s1))) 'g)
  (check-equal? (selection-set-selections (selection-set-remove g (list s2))) (list s1 s3))
  (check-equal? (selection-set-leader (selection-set-put-leader g s3)) s3)
  (check-equal? (selection-set-leader (selection-set-map (selection-set-open 'g (list s1 s2) 1)
                                         (lambda (s) (caret (selection-anchor s)))))
                (caret (P 0 8)))

  ;; 清除：单个选区 = leader，名字丢弃
  (define gc2 (selection-set-clear g))
  (check-false (selection-set-name gc2))
  (check-equal? (selection-set-selections gc2) (list s2))
  (check-equal? (selection-set-leader gc2) s2)

  ;; 编辑后重定位：插入 "XX" 在位置 (0,4)；free 平移，leader 前进
  (define dins (edit-desc (P 0 4) (P 0 4) "XX"))
  (check-equal? (map selection-head (selection-set-selections (selection-set-map-edit g (list dins))))
                (list (P 0 3) (P 0 13) (P 0 21)))
  (check-equal? (selection-set-leader (selection-set-advance-leader g (list dins)))
                (caret (P 0 13)))

  (displayln "selection-set.rkt: all tests passed"))
