# frozen_string_literal: true

RSpec.describe AmazonSnsHelper do
  fab!(:user)
  let(:test_arn) { "sample:arn2" }
  let!(:subscription) do
    AmazonSnsSubscription.create!(
      user_id: user.id,
      device_token: "some_token",
      application_name: "application_name",
      platform: "ios",
      endpoint_arn: test_arn,
    )
  end
  let(:mock_response) { stub }

  before do
    SiteSetting.amazon_sns_region = "us-west-2"
    SiteSetting.amazon_sns_access_key_id = "access_key_id"
    SiteSetting.amazon_sns_secret_access_key = "secret_key"
    SiteSetting.amazon_sns_apns_application_arn = "test_apple_arn"
    SiteSetting.amazon_sns_data_only = false
  end

  context "when the SNS endpoint has been disabled" do
    before do
      Aws::SNS::Client
        .any_instance
        .expects(:publish)
        .raises(Aws::SNS::Errors::EndpointDisabled.new(stub, "message"))
      Aws::SNS::Client
        .any_instance
        .expects(:delete_endpoint)
        .with(endpoint_arn: test_arn)
        .at_least(1)
    end

    it "disables the subscription and deletes the endpoint for publish_ios" do
      described_class.publish_ios(user, test_arn, {}, true)
      subscription.reload
      expect(subscription.status).to eq(AmazonSnsSubscription.statuses[:disabled])
      expect(subscription.status_changed_at).not_to eq(nil)
    end

    it "disables the subscription and deletes the endpoint for publish_android" do
      described_class.publish_android(user, test_arn, {})
      subscription.reload
      expect(subscription.status).to eq(AmazonSnsSubscription.statuses[:disabled])
      expect(subscription.status_changed_at).not_to eq(nil)
    end
  end

  context "when the SNS endpoint does not exist with TargetArn error" do
    before do
      Aws::SNS::Client
        .any_instance
        .expects(:publish)
        .raises(Aws::SNS::Errors::InvalidParameter.new(stub, "TargetArn does not exist"))
    end

    it "destroys the subscription for publish_ios" do
      described_class.publish_ios(user, test_arn, {}, true)
      expect(AmazonSnsSubscription.find_by(id: subscription.id)).to eq(nil)
    end

    it "destroys the subscription for publish_android" do
      described_class.publish_android(user, test_arn, {})
      expect(AmazonSnsSubscription.find_by(id: subscription.id)).to eq(nil)
    end
  end

  describe "publish_android when amazon_sns_data_only is false" do
    let(:client) { Aws::SNS::Client.new(stub_responses: true) }

    before do
      allow(described_class).to receive(:sns_client).and_return(client)
      allow(client).to receive(:publish).and_return(mock_response)
    end

    context "when use_title_and_body is true" do
      let(:payload) do
        { use_title_and_body: true, title: "Test Title", body: "Test Body", post_url: "/test/url" }
      end

      it "uses title and body directly" do
        described_class.publish_android(user, test_arn, payload)

        expected_message = {
          gcm: {
            data: {
              message: "Test Body",
              url: "#{Discourse.base_url_no_prefix}/test/url",
              notification_type: "",
              direct_message: "false",
            },
            notification: {
              title: "Test Title",
              body: "Test Body",
            },
          }.to_json,
        }.to_json

        expect(client).to have_received(:publish).with(
          target_arn: test_arn,
          message: expected_message,
          message_structure: "json",
        )
      end
    end

    context "when use_title_and_body is false" do
      let(:payload) do
        {
          topic_title: "Topic Title",
          username: "username",
          excerpt: "Excerpt",
          post_url: "/test/url",
        }
      end

      it "generates a message using topic title and excerpt" do
        allow(described_class).to receive(:generate_message).and_return("@username: Excerpt")

        described_class.publish_android(user, test_arn, payload)

        expected_message = {
          gcm: {
            data: {
              message: "@username: Excerpt",
              url: "#{Discourse.base_url_no_prefix}/test/url",
              notification_type: "",
              direct_message: "false",
            },
            notification: {
              title: "Topic Title",
              body: "@username: Excerpt",
            },
          }.to_json,
        }.to_json

        expect(client).to have_received(:publish).with(
          target_arn: test_arn,
          message: expected_message,
          message_structure: "json",
        )
      end
    end
  end

  describe "publish_android when amazon_sns_data_only is true" do
    let(:client) { Aws::SNS::Client.new(stub_responses: true) }

    before do
      allow(described_class).to receive(:sns_client).and_return(client)
      allow(client).to receive(:publish).and_return(mock_response)
      SiteSetting.amazon_sns_data_only = true
    end

    context "when use_title_and_body is true" do
      let(:payload) do
        { use_title_and_body: true, title: "Test Title", body: "Test Body", post_url: "/test/url" }
      end

      it "uses title and body directly" do
        described_class.publish_android(user, test_arn, payload)

        expected_message = {
          gcm: {
            data: {
              title: "Test Title",
              body: "Test Body",
              message: "Test Body",
              url: "#{Discourse.base_url_no_prefix}/test/url",
              notification_type: "",
              direct_message: "false",
            },
            priority: "high",
          }.to_json,
        }.to_json

        expect(client).to have_received(:publish).with(
          target_arn: test_arn,
          message: expected_message,
          message_structure: "json",
        )
      end
    end

    context "when use_title_and_body is false" do
      let(:payload) do
        {
          topic_title: "Topic Title",
          username: "username",
          excerpt: "Excerpt",
          post_url: "/test/url",
        }
      end

      it "generates a message using topic title and excerpt" do
        allow(described_class).to receive(:generate_message).and_return("@username: Excerpt")

        described_class.publish_android(user, test_arn, payload)

        expected_message = {
          gcm: {
            data: {
              title: "Topic Title",
              body: "@username: Excerpt",
              message: "@username: Excerpt",
              url: "#{Discourse.base_url_no_prefix}/test/url",
              notification_type: "",
              direct_message: "false",
            },
            priority: "high",
          }.to_json,
        }.to_json

        expect(client).to have_received(:publish).with(
          target_arn: test_arn,
          message: expected_message,
          message_structure: "json",
        )
      end
    end
  end

  describe "publish_android category data" do
    let(:client) { Aws::SNS::Client.new(stub_responses: true) }

    fab!(:topic)
    fab!(:private_message_topic)

    before { allow(described_class).to receive(:sns_client).and_return(client) }

    def published_data(payload)
      data = nil
      allow(client).to receive(:publish) do |args|
        data = JSON.parse(JSON.parse(args[:message])["gcm"])["data"]
        mock_response
      end
      described_class.publish_android(user, test_arn, payload)
      data
    end

    it "marks replies in a regular topic as not direct messages" do
      data =
        published_data(
          notification_type: Notification.types[:replied],
          topic_id: topic.id,
          post_url: "/t/#{topic.slug}/#{topic.id}/2",
        )

      expect(data).to include("notification_type" => "replied", "direct_message" => "false")
    end

    it "marks personal messages as direct messages" do
      data =
        published_data(
          notification_type: Notification.types[:private_message],
          topic_id: private_message_topic.id,
          post_url: "/t/#{private_message_topic.slug}/#{private_message_topic.id}",
        )

      expect(data).to include("notification_type" => "private_message", "direct_message" => "true")
    end

    it "marks chat direct message channels as direct messages" do
      data =
        published_data(
          notification_type: Notification.types[:chat_message],
          is_direct_message_channel: true,
          post_url: "/chat/c/-/1/2",
        )

      expect(data).to include("notification_type" => "chat_message", "direct_message" => "true")
    end

    it "marks public chat channels as not direct messages" do
      data =
        published_data(
          notification_type: Notification.types[:chat_mention],
          is_direct_message_channel: false,
          post_url: "/chat/c/general/1/2",
        )

      expect(data).to include("notification_type" => "chat_mention", "direct_message" => "false")
    end

    it "includes the category data in data-only messages" do
      SiteSetting.amazon_sns_data_only = true

      data =
        published_data(
          notification_type: Notification.types[:replied],
          topic_id: topic.id,
          topic_title: "Topic Title",
          post_url: "/t/#{topic.slug}/#{topic.id}/2",
        )

      expect(data).to include(
        "title" => "Topic Title",
        "notification_type" => "replied",
        "direct_message" => "false",
      )
    end
  end
end
