# frozen_string_literal: true

module UsageCredits
  # Extension to PaddleRails::Subscription to refill user credits
  # Mirrors PaySubscriptionExtension with adaptations for PaddleRails:
  #   - owner is a direct polymorphic association (not customer.owner)
  #   - price ID comes from SubscriptionItem records (or raw_payload fallback)
  #   - period dates use PaddleRails naming conventions
  #
  # @see PaySubscriptionExtension for the equivalent Pay integration
  module PaddleRailsSubscriptionExtension
    extend ActiveSupport::Concern

    included do
      after_commit :handle_initial_award_and_fulfillment_setup
      after_commit :update_fulfillment_on_renewal,      if: :subscription_renewed?
      after_commit :update_fulfillment_on_cancellation,  if: :subscription_canceled?
      after_commit :handle_plan_change_wrapper
    end

    # Extract the primary Paddle price ID from subscription items,
    # falling back to raw_payload when items aren't yet synced (initial creation timing issue)
    def paddle_processor_plan
      item = items.find_by(recurring: true) || items.first
      return item.price.paddle_price_id if item&.price

      # Fallback to raw_payload for initial creation (items not yet synced)
      items_data = raw_payload&.dig("items") || []
      first_recurring = items_data.find { |i| i["recurring"] == true } || items_data.first
      first_recurring&.dig("price", "id")
    end

    # Identify the usage_credits plan object
    def credit_subscription_plan
      UsageCredits.configuration.find_subscription_plan_by_processor_id(paddle_processor_plan)
    end

    def provides_credits?
      credit_subscription_plan.present?
    end

    def fulfillment_should_stop_at
      scheduled_cancelation_at || current_period_end_at
    end

    private

    # Returns true if the subscription has a valid credit wallet to operate on
    def has_valid_wallet?
      return false unless owner&.respond_to?(:credit_wallet)
      return false unless owner.credit_wallet.present?
      true
    end

    def credits_already_fulfilled?
      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return false unless fulfillment

      # A stopped fulfillment should NOT prevent reactivation
      return false if fulfillment.stops_at.present? && fulfillment.stops_at <= Time.current

      # A fulfillment scheduled to stop should also allow reactivation
      return false if fulfillment.metadata["stopped_reason"].present?

      true
    end

    # Returns an existing fulfillment that is stopped or scheduled to stop
    def reactivatable_fulfillment
      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return nil unless fulfillment

      is_stopped = fulfillment.stops_at.present? && fulfillment.stops_at <= Time.current
      is_scheduled_to_stop = fulfillment.metadata["stopped_reason"].present?

      return nil unless is_stopped || is_scheduled_to_stop
      fulfillment
    end

    def subscription_renewed?
      saved_change_to_current_period_end_at? && status == "active"
    end

    def subscription_canceled?
      saved_change_to_status? && status == "canceled"
    end

    def plan_changed?
      # PaddleRails doesn't have a processor_plan column, so we can't use
      # saved_change_to_processor_plan?. Instead, we only check for plan changes
      # when raw_payload actually changed (which happens when Paddle sends a
      # subscription.updated webhook with new item/price data).
      return false unless saved_change_to_raw_payload? && status == "active"

      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return false unless fulfillment

      current_plan_id = fulfillment.metadata["plan"]
      new_plan_id = paddle_processor_plan

      # No change
      return false if current_plan_id == new_plan_id

      # Only trigger if the old plan was a credit plan
      old_plan = UsageCredits.configuration.find_subscription_plan_by_processor_id(current_plan_id)
      return false unless old_plan.present?

      true
    end

    # =========================================
    # Period helpers
    # =========================================

    def current_period_start_at
      value = raw_payload&.dig("current_billing_period", "starts_at")
      Time.parse(value) if value.present?
    rescue ArgumentError
      nil
    end

    # =========================================
    # Actual fulfillment logic
    # =========================================

    def handle_initial_award_and_fulfillment_setup
      return unless provides_credits?
      return unless has_valid_wallet?
      return unless ["trialing", "active"].include?(status)

      existing_reactivatable_fulfillment = reactivatable_fulfillment
      is_reactivation = existing_reactivatable_fulfillment.present?

      return if credits_already_fulfilled?

      plan = credit_subscription_plan
      wallet = owner.credit_wallet

      credits_expire_at = calculate_credit_expiration(plan, current_period_start_at)

      Rails.logger.info "Fulfilling #{is_reactivation ? 'reactivation' : 'initial'} credits for PaddleRails subscription #{id}"
      Rails.logger.info "  Status: #{status}"
      Rails.logger.info "  Plan: #{plan}"

      total_credits_awarded = 0
      last_credit_transaction = nil

      ActiveRecord::Base.transaction do
        transaction_ids = []

        if status == "trialing" && plan.trial_credits.positive?
          last_credit_transaction = wallet.add_credits(plan.trial_credits,
            category: "subscription_trial",
            expires_at: trial_ends_at,
            metadata: {
              subscription_id: id,
              reason: is_reactivation ? "reactivation_trial_credits" : "initial_trial_credits",
              plan: paddle_processor_plan,
              fulfilled_at: Time.current
            }
          )
          transaction_ids << last_credit_transaction.id
          total_credits_awarded += plan.trial_credits

        elsif status == "active"
          if plan.signup_bonus_credits.positive? && !is_reactivation
            bonus_transaction = wallet.add_credits(plan.signup_bonus_credits,
              category: "subscription_signup_bonus",
              metadata: {
                subscription_id: id,
                reason: "signup_bonus",
                plan: paddle_processor_plan,
                fulfilled_at: Time.current
              }
            )
            transaction_ids << bonus_transaction.id
            total_credits_awarded += plan.signup_bonus_credits
            last_credit_transaction = bonus_transaction
          end

          if plan.credits_per_period.positive?
            credits_transaction = wallet.add_credits(plan.credits_per_period,
              category: "subscription_credits",
              expires_at: credits_expire_at,
              metadata: {
                subscription_id: id,
                reason: is_reactivation ? "reactivation" : "first_cycle",
                plan: paddle_processor_plan,
                fulfilled_at: Time.current
              }
            )
            transaction_ids << credits_transaction.id
            total_credits_awarded += plan.credits_per_period
            last_credit_transaction = credits_transaction
          end
        end

        # Create or reactivate Fulfillment record
        period_start = if trial_ends_at && status == "trialing"
                        trial_ends_at
                      else
                        current_period_start_at || Time.current
                      end

        next_fulfillment_at = period_start + plan.parsed_fulfillment_period
        next_fulfillment_at = Time.current + plan.parsed_fulfillment_period if next_fulfillment_at <= Time.current

        if is_reactivation
          existing_reactivatable_fulfillment.update!(
            credits_last_fulfillment: total_credits_awarded,
            fulfillment_period: plan.fulfillment_period_display,
            last_fulfilled_at: Time.current,
            next_fulfillment_at: next_fulfillment_at,
            stops_at: fulfillment_should_stop_at,
            metadata: existing_reactivatable_fulfillment.metadata
              .except("stopped_reason", "stopped_at", "pending_plan_change", "plan_change_at")
              .merge(
                "subscription_id" => id,
                "plan" => paddle_processor_plan,
                "reactivated_at" => Time.current
              )
          )

          Rails.logger.info "Reactivated fulfillment #{existing_reactivatable_fulfillment.id} for PaddleRails subscription #{id}"
        else
          UsageCredits::Fulfillment.create!(
            wallet: wallet,
            source: self,
            fulfillment_type: "subscription",
            credits_last_fulfillment: total_credits_awarded,
            fulfillment_period: plan.fulfillment_period_display,
            last_fulfilled_at: Time.current,
            next_fulfillment_at: next_fulfillment_at,
            stops_at: fulfillment_should_stop_at,
            metadata: {
              "subscription_id" => id,
              "plan" => paddle_processor_plan,
            }
          )

          Rails.logger.info "Initial fulfillment for PaddleRails subscription #{id} finished"
        end

        fulfillment_record = UsageCredits::Fulfillment.find_by(source: self)
        UsageCredits::Transaction.where(id: transaction_ids).update_all(fulfillment_id: fulfillment_record&.id) if transaction_ids.any?
      end

      if total_credits_awarded > 0
        UsageCredits::Callbacks.dispatch(:subscription_credits_awarded,
          wallet: wallet,
          amount: total_credits_awarded,
          transaction: last_credit_transaction,
          metadata: {
            subscription_plan_name: plan.name,
            subscription: plan,
            paddle_subscription: self,
            fulfillment_period: plan.fulfillment_period_display,
            is_reactivation: is_reactivation,
            status: status
          }
        )
      end

    rescue => e
      Rails.logger.error "Failed to fulfill initial credits for PaddleRails subscription #{id}: #{e.message}"
      raise
    end

    def update_fulfillment_on_renewal
      return unless provides_credits? && has_valid_wallet?

      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return unless fulfillment

      ActiveRecord::Base.transaction do
        if fulfillment.metadata["pending_plan_change"].present?
          apply_pending_plan_change(fulfillment)
        end

        fulfillment.update!(stops_at: fulfillment_should_stop_at)
        Rails.logger.info "Fulfillment #{fulfillment.id} stops_at updated to #{fulfillment.stops_at}"
      rescue => e
        Rails.logger.error "Failed to extend fulfillment period for PaddleRails subscription #{id}: #{e.message}"
        raise ActiveRecord::Rollback
      end
    end

    def update_fulfillment_on_cancellation
      plan = credit_subscription_plan
      return unless plan && has_valid_wallet?

      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return unless fulfillment

      ActiveRecord::Base.transaction do
        fulfillment.update!(stops_at: fulfillment_should_stop_at)
        Rails.logger.info "Fulfillment #{fulfillment.id} stops_at set to #{fulfillment.stops_at} due to cancellation"
      rescue => e
        Rails.logger.error "Failed to stop credit fulfillment for PaddleRails subscription #{id}: #{e.message}"
        raise ActiveRecord::Rollback
      end
    end

    def handle_plan_change_wrapper
      return unless plan_changed?
      handle_plan_change
    end

    def handle_plan_change
      return unless has_valid_wallet?

      fulfillment = UsageCredits::Fulfillment.find_by(source: self)
      return unless fulfillment

      Rails.logger.info "=" * 80
      Rails.logger.info "[UsageCredits] Plan change detected for PaddleRails subscription #{id}"

      current_plan_id = fulfillment.metadata["plan"]
      new_plan_id = paddle_processor_plan

      current_plan = UsageCredits.configuration.find_subscription_plan_by_processor_id(current_plan_id)
      new_plan = UsageCredits.configuration.find_subscription_plan_by_processor_id(new_plan_id)

      # Handle downgrade to a non-credit plan
      if new_plan.nil? && current_plan.present?
        handle_downgrade_to_non_credit_plan(fulfillment)
        return
      end

      return unless new_plan

      ActiveRecord::Base.transaction do
        if current_plan_id == new_plan_id
          Rails.logger.info "  Action: Returning to current plan (clearing pending change)"
          clear_pending_plan_change(fulfillment)
          return
        end

        current_credits = current_plan&.credits_per_period || 0
        new_credits = new_plan.credits_per_period

        if new_credits > current_credits
          handle_plan_upgrade(new_plan, fulfillment)
        elsif new_credits < current_credits
          handle_plan_downgrade(new_plan, fulfillment)
        else
          update_fulfillment_plan_metadata(fulfillment, new_plan_id)
        end
      rescue => e
        Rails.logger.error "Failed to handle plan change for PaddleRails subscription #{id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        raise ActiveRecord::Rollback
      end

      Rails.logger.info "  Plan change completed successfully"
      Rails.logger.info "=" * 80
    end

    def handle_plan_upgrade(new_plan, fulfillment)
      wallet = owner.credit_wallet

      credits_expire_at = calculate_credit_expiration(new_plan, current_period_end_at)
      next_fulfillment_at = Time.current + new_plan.parsed_fulfillment_period

      upgrade_transaction = nil

      ActiveRecord::Base.transaction do
        # Expire remaining subscription credits from the old plan to prevent
        # credit accumulation when upgrading/downgrading repeatedly.
        # Only expires subscription-related credits for this subscription;
        # signup bonuses, credit packs, and manual adjustments are preserved.
        expire_previous_subscription_credits(wallet)

        upgrade_transaction = wallet.add_credits(
          new_plan.credits_per_period,
          category: "subscription_upgrade",
          expires_at: credits_expire_at,
          metadata: {
            "subscription_id" => id,
            "plan" => paddle_processor_plan,
            "reason" => "plan_upgrade",
            "fulfilled_at" => Time.current
          }
        )

        fulfillment.update!(
          fulfillment_period: new_plan.fulfillment_period_display,
          next_fulfillment_at: next_fulfillment_at,
          metadata: fulfillment.metadata
            .except("pending_plan_change", "plan_change_at")
            .merge("plan" => paddle_processor_plan)
        )
      end

      UsageCredits::Callbacks.dispatch(:subscription_credits_awarded,
        wallet: wallet,
        amount: new_plan.credits_per_period,
        transaction: upgrade_transaction,
        metadata: {
          subscription_plan_name: new_plan.name,
          subscription: new_plan,
          paddle_subscription: self,
          fulfillment_period: new_plan.fulfillment_period_display,
          reason: "plan_upgrade"
        }
      )

      Rails.logger.info "PaddleRails subscription #{id} upgraded to #{paddle_processor_plan}, granted #{new_plan.credits_per_period} credits"
    end

    def handle_plan_downgrade(new_plan, fulfillment)
      wallet = owner.credit_wallet

      credits_expire_at = calculate_credit_expiration(new_plan, current_period_end_at)
      next_fulfillment_at = Time.current + new_plan.parsed_fulfillment_period

      downgrade_transaction = nil

      ActiveRecord::Base.transaction do
        # Expire remaining subscription credits from the old plan.
        # Paddle processes downgrades immediately (prorated_immediately),
        # so credits should match the new plan right away.
        expire_previous_subscription_credits(wallet)

        downgrade_transaction = wallet.add_credits(
          new_plan.credits_per_period,
          category: "subscription_credits",
          expires_at: credits_expire_at,
          metadata: {
            "subscription_id" => id,
            "plan" => paddle_processor_plan,
            "reason" => "plan_downgrade",
            "fulfilled_at" => Time.current
          }
        )

        fulfillment.update!(
          fulfillment_period: new_plan.fulfillment_period_display,
          next_fulfillment_at: next_fulfillment_at,
          metadata: fulfillment.metadata
            .except("pending_plan_change", "plan_change_at")
            .merge("plan" => paddle_processor_plan)
        )
      end

      UsageCredits::Callbacks.dispatch(:subscription_credits_awarded,
        wallet: wallet,
        amount: new_plan.credits_per_period,
        transaction: downgrade_transaction,
        metadata: {
          subscription_plan_name: new_plan.name,
          subscription: new_plan,
          paddle_subscription: self,
          fulfillment_period: new_plan.fulfillment_period_display,
          reason: "plan_downgrade"
        }
      )

      Rails.logger.info "PaddleRails subscription #{id} downgraded to #{paddle_processor_plan}, granted #{new_plan.credits_per_period} credits"
    end

    def handle_downgrade_to_non_credit_plan(fulfillment)
      schedule_time = [current_period_end_at || Time.current, Time.current].max

      ActiveRecord::Base.transaction do
        fulfillment.update!(
          stops_at: schedule_time,
          metadata: fulfillment.metadata.merge(
            "stopped_reason" => "downgrade_to_non_credit_plan",
            "stopped_at" => schedule_time
          )
        )

        Rails.logger.info "PaddleRails subscription #{id} downgraded to non-credit plan, fulfillment will stop at #{schedule_time}"
      rescue => e
        Rails.logger.error "Failed to handle downgrade to non-credit plan for PaddleRails subscription #{id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        raise ActiveRecord::Rollback
      end
    end

    def update_fulfillment_plan_metadata(fulfillment, new_plan_id)
      fulfillment.update!(
        metadata: fulfillment.metadata.merge("plan" => new_plan_id)
      )
    end

    def clear_pending_plan_change(fulfillment)
      return unless fulfillment.metadata["pending_plan_change"].present?

      fulfillment.update!(
        metadata: fulfillment.metadata.except("pending_plan_change", "plan_change_at")
      )

      Rails.logger.info "PaddleRails subscription #{id} pending plan change cleared (returned to current plan)"
    end

    def apply_pending_plan_change(fulfillment)
      pending_plan = fulfillment.metadata["pending_plan_change"]

      unless UsageCredits.configuration.find_subscription_plan_by_processor_id(pending_plan)
        Rails.logger.error "Cannot apply pending plan change for PaddleRails subscription #{id}: plan '#{pending_plan}' not found in configuration"
        fulfillment.update!(
          metadata: fulfillment.metadata.except("pending_plan_change", "plan_change_at")
        )
        return
      end

      fulfillment.update!(
        metadata: fulfillment.metadata
          .except("pending_plan_change", "plan_change_at")
          .merge("plan" => pending_plan)
      )

      Rails.logger.info "Applied pending plan change for PaddleRails subscription #{id}: now on #{pending_plan}"
    end

    # =========================================
    # Helper Methods
    # =========================================

    # Expire remaining subscription credits from the current plan.
    # This prevents credit accumulation when users upgrade/downgrade repeatedly.
    # Only targets renewable subscription credits (subscription_credits, subscription_upgrade);
    # signup bonuses, trial credits, credit packs, and manual adjustments are preserved.
    def expire_previous_subscription_credits(wallet)
      subscription_categories = %w[subscription_credits subscription_upgrade]

      expired_count = wallet.transactions
        .where(category: subscription_categories)
        .where("amount > 0")
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .update_all(expires_at: Time.current)

      if expired_count > 0
        # Sync wallet balance after expiring old credits
        wallet.with_lock do
          wallet.balance = wallet.credits
          wallet.save!
        end
        Rails.logger.info "  Expired #{expired_count} previous subscription credit transaction(s) for subscription #{id}"
      end
    end

    def calculate_credit_expiration(plan, base_time = nil)
      return nil if plan.rollover_enabled

      effective_base = [base_time || Time.current, Time.current].max

      fulfillment_period = plan.parsed_fulfillment_period
      effective_grace = [
        UsageCredits.configuration.fulfillment_grace_period,
        fulfillment_period
      ].min

      effective_base + fulfillment_period + effective_grace
    end
  end
end
